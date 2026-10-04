begin;

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  machine_id uuid not null references public.machines(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  price_cents integer not null check (price_cents > 0),
  currency text not null check (currency = 'BRL'),
  status text not null default 'WAITING_PAYMENT'
    check (status in ('WAITING_PAYMENT', 'CANCELLED', 'EXPIRED')),
  idempotency_key uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  check (expires_at > created_at),
  unique (user_id, idempotency_key),
  unique (id, machine_id)
);
create index orders_user_created_idx on public.orders(user_id, created_at desc);
create index orders_machine_idx on public.orders(machine_id);
create index orders_service_idx on public.orders(service_id);
create index orders_pending_expiry_idx on public.orders(expires_at)
  where status = 'WAITING_PAYMENT';

create table public.machine_reservations (
  id uuid primary key default gen_random_uuid(),
  machine_id uuid not null references public.machines(id) on delete restrict,
  order_id uuid not null unique,
  acquired_at timestamptz not null default clock_timestamp(),
  released_at timestamptz,
  foreign key (order_id, machine_id) references public.orders(id, machine_id) on delete restrict,
  check (released_at is null or released_at >= acquired_at)
);
create unique index one_open_reservation_per_machine
  on public.machine_reservations(machine_id) where released_at is null;

alter table public.orders enable row level security;
alter table public.machine_reservations enable row level security;
revoke all on public.orders, public.machine_reservations from public, anon, authenticated, service_role;
grant select on public.orders to authenticated, service_role;
grant select on public.machine_reservations to service_role;
create policy orders_read_own on public.orders for select to authenticated
  using (user_id = (select auth.uid()));

-- Somente backend. p_user_id deve vir da identidade validada, nunca do body do cliente.
create function public.create_order(
  p_user_id uuid, p_machine_id uuid, p_service_id uuid, p_idempotency_key uuid
) returns public.orders language plpgsql security definer set search_path = '' as $$
declare
  v_order public.orders;
  v_machine public.machines;
  v_service public.services;
  v_now timestamptz;
begin
  if p_user_id is null or p_machine_id is null or p_service_id is null or p_idempotency_key is null then
    raise exception 'INVALID_REQUEST' using errcode = '22023';
  end if;
  -- Serializa a chave mesmo quando dois retries citam máquinas distintas.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_user_id::text || ':' || p_idempotency_key::text, 0));
  select * into v_order from public.orders
    where user_id = p_user_id and idempotency_key = p_idempotency_key;
  if found then
    if v_order.machine_id <> p_machine_id or v_order.service_id <> p_service_id then
      raise exception 'IDEMPOTENCY_CONFLICT' using errcode = '22023';
    end if;
    return v_order;
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'PROFILE_NOT_FOUND' using errcode = '22023';
  end if;
  select * into v_machine from public.machines where id = p_machine_id for update;
  if not found then
    raise exception 'MACHINE_NOT_FOUND' using errcode = '22023';
  end if;
  v_now := clock_timestamp();
  if v_machine.operational_status <> 'ACTIVE' then
    raise exception 'MACHINE_UNAVAILABLE' using errcode = 'P0001';
  end if;
  -- Limite inicial de 2 minutos, fixo no backend; não configurável pelo cliente.
  if v_machine.last_seen_at is null or v_machine.last_seen_at < v_now - interval '2 minutes'
    or v_machine.last_seen_at > v_now then
    raise exception 'MACHINE_OFFLINE' using errcode = 'P0001';
  end if;
  select * into v_service from public.services where id = p_service_id for share;
  if not found then
    raise exception 'SERVICE_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if not v_service.active then
    raise exception 'SERVICE_UNAVAILABLE' using errcode = 'P0001';
  end if;
  perform 1 from public.machine_services
    where machine_id = p_machine_id and service_id = p_service_id for share;
  if not found then
    raise exception 'SERVICE_INCOMPATIBLE' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.machine_reservations
    where machine_id = p_machine_id and released_at is null) then
    raise exception 'MACHINE_RESERVED' using errcode = 'P0001';
  end if;
  insert into public.orders(user_id, machine_id, service_id, price_cents, currency,
    idempotency_key, created_at, expires_at)
  values (p_user_id, p_machine_id, p_service_id, v_service.price_cents, v_service.currency,
    p_idempotency_key, v_now, v_now + interval '10 minutes') returning * into v_order;
  insert into public.machine_reservations(machine_id, order_id) values (p_machine_id, v_order.id);
  return v_order;
end;
$$;

create function public.cancel_order(p_user_id uuid, p_order_id uuid)
returns public.orders language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_machine_id uuid;
begin
  select machine_id into v_machine_id from public.orders where id = p_order_id and user_id = p_user_id;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = '22023';
  end if;
  -- Toda operação de reserva bloqueia máquina antes do pedido.
  perform 1 from public.machines where id = v_machine_id for update;
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order.status <> 'WAITING_PAYMENT' then return v_order; end if;
  update public.orders set status = case when expires_at <= clock_timestamp()
    then 'EXPIRED' else 'CANCELLED' end where id = p_order_id returning * into v_order;
  update public.machine_reservations set released_at = clock_timestamp()
    where order_id = p_order_id and released_at is null;
  return v_order;
end;
$$;

-- Operação por pedido, chamada por worker futuro. Não instala cron neste incremento.
create function public.expire_order(p_order_id uuid)
returns public.orders language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_machine_id uuid;
begin
  select machine_id into v_machine_id from public.orders where id = p_order_id;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = '22023'; end if;
  perform 1 from public.machines where id = v_machine_id for update;
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order.status = 'WAITING_PAYMENT' and v_order.expires_at <= clock_timestamp() then
    update public.orders set status = 'EXPIRED' where id = p_order_id returning * into v_order;
    update public.machine_reservations set released_at = clock_timestamp()
      where order_id = p_order_id and released_at is null;
  end if;
  return v_order;
end;
$$;

revoke all on function public.create_order(uuid, uuid, uuid, uuid),
  public.cancel_order(uuid, uuid), public.expire_order(uuid) from public, anon, authenticated;
grant execute on function public.create_order(uuid, uuid, uuid, uuid),
  public.cancel_order(uuid, uuid), public.expire_order(uuid) to service_role;

comment on function public.expire_order(uuid) is
  'Pré-pagamentos: integrar reconciliação de cobrança antes de habilitar gateway.';
commit;
