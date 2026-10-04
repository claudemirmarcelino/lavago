begin;

alter table public.orders drop constraint orders_status_check;
alter table public.orders add constraint orders_status_check check
  (status in ('WAITING_PAYMENT', 'AUTHORIZED', 'NEEDS_REVIEW', 'CANCELLED', 'EXPIRED'));
alter table public.payments add column reconciliation_reason text
  check (reconciliation_reason in ('AMOUNT_MISMATCH', 'ORDER_NOT_PAYABLE',
    'RESERVATION_INVALID', 'MACHINE_UNAVAILABLE', 'EXTRA_PAYMENT'));

-- Chamável somente pelo backend após verificação externa. Nenhum endpoint público.
create function public.record_verified_payment(
  p_order_id uuid, p_provider text, p_payment_id text, p_event_id text,
  p_amount_cents bigint, p_currency text
) returns public.orders language plpgsql security definer set search_path = '' as $$
declare
  v_order public.orders;
  v_payment public.payments;
  v_event public.payment_webhook_events;
  v_machine public.machines;
  v_machine_id uuid;
  v_reason text;
  v_cycle_id uuid;
  v_command_id uuid;
  v_now timestamptz;
  v_already_approved boolean := false;
begin
  if p_order_id is null or p_provider is null or p_payment_id is null or p_event_id is null
    or char_length(btrim(p_provider)) not between 1 and 50
    or char_length(btrim(p_payment_id)) not between 1 and 200
    or char_length(btrim(p_event_id)) not between 1 and 200
    or p_amount_cents is null or p_amount_cents <= 0
    or p_currency is null or p_currency !~ '^[A-Z]{3}$' then
    raise exception 'INVALID_PAYMENT_EVENT' using errcode = '22023';
  end if;
  -- Ordem global: evento → cobrança → máquina → pedido.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'event:' || p_provider || ':' || p_event_id, 0));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'payment:' || p_provider || ':' || p_payment_id, 0));
  select machine_id into v_machine_id from public.orders where id = p_order_id;
  if not found then raise exception 'ORDER_NOT_FOUND' using errcode = '22023'; end if;
  select * into v_machine from public.machines where id = v_machine_id for update;
  select * into v_order from public.orders where id = p_order_id for update;
  v_now := clock_timestamp();

  select * into v_payment from public.payments
    where provider = p_provider and provider_payment_id = p_payment_id for update;
  if found then
    if v_payment.order_id <> p_order_id or v_payment.amount_cents <> p_amount_cents
      or v_payment.currency <> p_currency then
      raise exception 'PAYMENT_IDENTITY_CONFLICT' using errcode = '22023';
    end if;
    if v_payment.status not in ('PENDING', 'APPROVED') then
      raise exception 'PAYMENT_REQUIRES_RECONCILIATION' using errcode = 'P0001';
    end if;
    v_already_approved := v_payment.status = 'APPROVED';
  end if;
  select * into v_event from public.payment_webhook_events
    where provider = p_provider and provider_event_id = p_event_id for update;
  if found then
    if v_event.payment_id is null or v_event.payment_id is distinct from v_payment.id then
      raise exception 'EVENT_IDENTITY_CONFLICT' using errcode = '22023';
    end if;
    if v_event.processing_status = 'PROCESSED' and v_already_approved then
      return v_order;
    end if;
    raise exception 'EVENT_REQUIRES_RECONCILIATION' using errcode = 'P0001';
  end if;

  if v_payment.id is null then
    insert into public.payments(order_id,provider,provider_payment_id,amount_cents,currency,status,confirmed_at)
      values(p_order_id,p_provider,p_payment_id,p_amount_cents,p_currency,'APPROVED',v_now)
      returning * into v_payment;
  elsif not v_already_approved then
    update public.payments set status='APPROVED',confirmed_at=v_now where id=v_payment.id
      returning * into v_payment;
  end if;
  insert into public.payment_webhook_events(provider,provider_event_id,payment_id,
    processing_status,attempts,processed_at)
    values(p_provider,p_event_id,v_payment.id,'PROCESSED',1,v_now) returning * into v_event;
  insert into public.audit_logs(actor_type,event_type,entity_type,entity_id,correlation_id)
    values('BACKEND','VERIFIED_EVENT_RECORDED','WEBHOOK',v_event.id,v_event.id);

  -- Outro evento para uma cobrança já aprovada nunca gera nova autorização.
  if v_already_approved then return v_order; end if;
  insert into public.audit_logs(actor_type,event_type,entity_type,entity_id,correlation_id)
    values('BACKEND','PAYMENT_CONFIRMED','PAYMENT',v_payment.id,v_event.id);

  if exists(select 1 from public.payments where order_id=p_order_id
    and id<>v_payment.id and status in ('APPROVED','REFUNDED')) then
    v_reason := 'EXTRA_PAYMENT';
  elsif p_amount_cents <> v_order.price_cents or p_currency <> v_order.currency then
    v_reason := 'AMOUNT_MISMATCH';
  elsif v_order.status <> 'WAITING_PAYMENT' or v_order.expires_at <= v_now then
    v_reason := 'ORDER_NOT_PAYABLE';
  elsif not exists(select 1 from public.machine_reservations
    where order_id=p_order_id and machine_id=v_machine_id and released_at is null) then
    v_reason := 'RESERVATION_INVALID';
  elsif v_machine.operational_status <> 'ACTIVE' or v_machine.last_seen_at is null
    or v_machine.last_seen_at < v_now - interval '2 minutes' or v_machine.last_seen_at > v_now
    or exists(select 1 from public.washing_cycles where machine_id=v_machine_id
      and status in ('PENDING_START','RUNNING','UNKNOWN')) then
    v_reason := 'MACHINE_UNAVAILABLE';
  end if;

  if v_reason is not null then
    update public.payments set reconciliation_reason=v_reason where id=v_payment.id;
    if v_order.status = 'WAITING_PAYMENT' then
      update public.orders set status='NEEDS_REVIEW' where id=p_order_id returning * into v_order;
    end if;
    insert into public.audit_logs(actor_type,event_type,entity_type,entity_id,correlation_id)
      values('BACKEND','PAYMENT_REVIEW_REQUIRED','PAYMENT',v_payment.id,v_event.id);
    return v_order;
  end if;

  update public.orders set status='AUTHORIZED' where id=p_order_id returning * into v_order;
  insert into public.washing_cycles(order_id,machine_id) values(p_order_id,v_machine_id)
    returning id into v_cycle_id;
  insert into public.automation_commands(cycle_id,machine_id,expires_at)
    values(v_cycle_id,v_machine_id,v_now+interval '2 minutes') returning id into v_command_id;
  insert into public.audit_logs(actor_type,event_type,entity_type,entity_id,correlation_id) values
    ('BACKEND','ORDER_AUTHORIZED','ORDER',p_order_id,v_event.id),
    ('BACKEND','CYCLE_CREATED','CYCLE',v_cycle_id,v_event.id),
    ('BACKEND','START_COMMAND_QUEUED','COMMAND',v_command_id,v_event.id);
  return v_order;
end;
$$;
revoke all on function public.record_verified_payment(uuid,text,text,text,bigint,text)
  from public, anon, authenticated;
grant execute on function public.record_verified_payment(uuid,text,text,text,bigint,text) to service_role;
comment on function public.record_verified_payment(uuid,text,text,text,bigint,text) is
  'Somente backend após validar gateway/assinatura/conta/cobrança. Sem endpoint de webhook público. Não envia comandos físicos.';
commit;
