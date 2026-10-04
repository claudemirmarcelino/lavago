begin;

-- Modelo de dados somente: operações financeiras e dispatcher ainda não habilitados.
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete restrict,
  provider text not null check (char_length(btrim(provider)) between 1 and 50),
  provider_payment_id text not null check (char_length(btrim(provider_payment_id)) between 1 and 200),
  amount_cents bigint not null check (amount_cents > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  status text not null default 'PENDING'
    check (status in ('PENDING', 'APPROVED', 'FAILED', 'CANCELLED', 'REFUNDED')),
  created_at timestamptz not null default clock_timestamp(),
  confirmed_at timestamptz,
  check ((status in ('APPROVED', 'REFUNDED')) = (confirmed_at is not null)),
  unique(provider, provider_payment_id)
);
create index payments_order_id_idx on public.payments(order_id);

create table public.washing_cycles (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique,
  machine_id uuid not null,
  status text not null default 'PENDING_START'
    check (status in ('PENDING_START', 'RUNNING', 'FINISHED', 'FAILED', 'UNKNOWN')),
  created_at timestamptz not null default clock_timestamp(),
  started_at timestamptz,
  finished_at timestamptz,
  foreign key(order_id, machine_id) references public.orders(id, machine_id) on delete restrict,
  unique(id, machine_id),
  check (status not in ('RUNNING', 'FINISHED') or started_at is not null),
  check (status <> 'PENDING_START' or started_at is null),
  check ((status = 'FINISHED') = (finished_at is not null)),
  check (finished_at is null or finished_at >= started_at)
);
-- UNKNOWN mantém exclusividade: não se sabe se a máquina ainda está em execução.
create unique index one_active_cycle_per_machine on public.washing_cycles(machine_id)
  where status in ('PENDING_START', 'RUNNING', 'UNKNOWN');
create index washing_cycles_machine_idx on public.washing_cycles(machine_id);

create table public.automation_commands (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null,
  machine_id uuid not null,
  command_type text not null default 'START' check (command_type = 'START'),
  status text not null default 'PENDING'
    check (status in ('PENDING', 'DISPATCHED', 'ACKNOWLEDGED', 'FAILED', 'EXPIRED', 'UNKNOWN')),
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  attempts integer not null default 0 check (attempts >= 0),
  lease_token uuid,
  lease_until timestamptz,
  acknowledged_at timestamptz,
  foreign key(cycle_id, machine_id) references public.washing_cycles(id, machine_id) on delete restrict,
  unique(cycle_id, command_type),
  check (expires_at > created_at),
  check ((lease_token is null) = (lease_until is null)),
  check ((status = 'ACKNOWLEDGED') = (acknowledged_at is not null))
);
create index automation_commands_pending_idx on public.automation_commands(created_at) where status = 'PENDING';
create index automation_commands_machine_idx on public.automation_commands(machine_id);

create table public.payment_webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (char_length(btrim(provider)) between 1 and 50),
  provider_event_id text not null check (char_length(btrim(provider_event_id)) between 1 and 200),
  payment_id uuid references public.payments(id) on delete restrict,
  processing_status text not null default 'RECEIVED'
    check (processing_status in ('RECEIVED', 'PROCESSED', 'FAILED', 'IGNORED')),
  attempts integer not null default 0 check (attempts >= 0),
  received_at timestamptz not null default clock_timestamp(),
  processed_at timestamptz,
  check ((processing_status in ('PROCESSED', 'IGNORED')) = (processed_at is not null)),
  unique(provider, provider_event_id)
);
create index webhook_events_payment_idx on public.payment_webhook_events(payment_id);
create index webhook_events_pending_idx on public.payment_webhook_events(received_at)
  where processing_status in ('RECEIVED', 'FAILED');

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_type text not null check (actor_type in ('USER', 'BACKEND', 'DEVICE', 'SYSTEM')),
  actor_id uuid,
  event_type text not null check (char_length(btrim(event_type)) between 1 and 100),
  entity_type text not null check (entity_type in ('ORDER', 'PAYMENT', 'CYCLE', 'COMMAND', 'WEBHOOK')),
  entity_id uuid not null,
  correlation_id uuid not null,
  created_at timestamptz not null default clock_timestamp()
);
create index audit_logs_entity_idx on public.audit_logs(entity_type, entity_id, created_at);
create index audit_logs_correlation_idx on public.audit_logs(correlation_id);

alter table public.payments enable row level security;
alter table public.washing_cycles enable row level security;
alter table public.automation_commands enable row level security;
alter table public.payment_webhook_events enable row level security;
alter table public.audit_logs enable row level security;
revoke all on public.payments, public.washing_cycles, public.automation_commands,
  public.payment_webhook_events, public.audit_logs from public, anon, authenticated, service_role;
grant select on public.payments, public.washing_cycles to authenticated;
grant select on public.payments, public.washing_cycles, public.automation_commands,
  public.payment_webhook_events, public.audit_logs to service_role;
create policy payments_read_own on public.payments for select to authenticated using (
  exists (select 1 from public.orders o where o.id = order_id and o.user_id = (select auth.uid()))
);
create policy cycles_read_own on public.washing_cycles for select to authenticated using (
  exists (select 1 from public.orders o where o.id = order_id and o.user_id = (select auth.uid()))
);

-- Fail closed até existir reconciliação: inclusive tentativa FAILED precisa ser revisada.
create function public.guard_order_release()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status and new.status in ('CANCELLED', 'EXPIRED') then
    if exists (select 1 from public.payments where order_id = old.id)
      or exists (select 1 from public.washing_cycles where order_id = old.id) then
      raise exception 'ORDER_REQUIRES_RECONCILIATION' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_order_release() from public, anon, authenticated, service_role;
create trigger orders_guard_release before update of status on public.orders
  for each row execute function public.guard_order_release();

comment on table public.payments is 'Valores observados do provedor; divergências são registráveis e exigem reconciliação. Sem endpoint de aprovação.';
comment on table public.automation_commands is 'Outbox estrutural; ACK é recebimento, não início físico. Sem dispatcher ou credenciais.';
comment on table public.audit_logs is 'Registro mínimo, sem payload bruto, secrets ou dados de cartão. Escrita por operações futuras revisadas.';
commit;
