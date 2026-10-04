begin;
alter table public.orders drop constraint orders_status_check;
alter table public.orders add constraint orders_status_check check
 (status in ('WAITING_PAYMENT','AUTHORIZED','IN_PROGRESS','COMPLETED','NEEDS_REVIEW','CANCELLED','EXPIRED'));
alter table public.washing_cycles add column last_evidence_at timestamptz;
alter table public.washing_cycles add column run_deadline_at timestamptz;

create table public.controller_events (
  id uuid primary key default gen_random_uuid(),
  machine_id uuid not null,
  command_id uuid not null references public.automation_commands(id) on delete restrict,
  event_id uuid not null,
  event_type text not null check(event_type in ('ACK','STARTED','HEARTBEAT','FINISHED')),
  received_at timestamptz not null default clock_timestamp(),
  unique(machine_id,event_id)
);
create index controller_events_command_idx on public.controller_events(command_id);
alter table public.controller_events enable row level security;
revoke all on public.controller_events from public,anon,authenticated,service_role;
grant select on public.controller_events to service_role;

-- Não reenvia DISPATCHED: sem deduplicação física persistente não é seguro repetir START.
create function public.claim_start_command(p_machine_id uuid)
returns public.automation_commands language plpgsql security definer set search_path='' as $$
declare m public.machines; c public.automation_commands; o public.orders; v_now timestamptz;
begin
  select * into m from public.machines where id=p_machine_id for update;
  if not found then raise exception 'MACHINE_NOT_FOUND' using errcode='22023'; end if;
  v_now:=clock_timestamp();
  if m.operational_status<>'ACTIVE' or m.last_seen_at is null
    or m.last_seen_at<v_now-interval '2 minutes' or m.last_seen_at>v_now then
    raise exception 'MACHINE_UNAVAILABLE' using errcode='P0001';
  end if;
  select a.* into c from public.automation_commands a join public.washing_cycles w on w.id=a.cycle_id
    where a.machine_id=p_machine_id and a.status='PENDING' and w.status='PENDING_START'
    and a.expires_at>v_now order by a.created_at limit 1;
  if not found then return null; end if;
  select o2.* into o from public.orders o2 join public.washing_cycles w on w.order_id=o2.id
    where w.id=c.cycle_id for update of o2;
  if o.status<>'AUTHORIZED' or not exists(select 1 from public.machine_reservations
    where order_id=o.id and machine_id=p_machine_id and released_at is null) then
    raise exception 'COMMAND_NOT_AUTHORIZED' using errcode='P0001';
  end if;
  update public.automation_commands set status='DISPATCHED', attempts=attempts+1,
    lease_token=gen_random_uuid(), lease_until=least(expires_at,v_now+interval '30 seconds')
    where id=c.id returning * into c;
  insert into public.audit_logs(actor_type,event_type,entity_type,entity_id,correlation_id)
    values('BACKEND','COMMAND_CLAIMED','COMMAND',c.id,c.id);
  return c;
end;
$$;

-- Backend autentica o controlador antes de informar máquina, evento e token de entrega.
create function public.record_controller_event(p_machine_id uuid,p_command_id uuid,
  p_lease_token uuid,p_event_id uuid,p_event_type text)
returns public.washing_cycles language plpgsql security definer set search_path='' as $$
declare c public.automation_commands; w public.washing_cycles; o public.orders;
  e public.controller_events; v_now timestamptz;
begin
  if p_machine_id is null or p_command_id is null or p_lease_token is null or p_event_id is null
    or p_event_type is null or p_event_type not in ('ACK','STARTED','HEARTBEAT','FINISHED') then
    raise exception 'INVALID_CONTROLLER_EVENT' using errcode='22023';
  end if;
  perform 1 from public.machines where id=p_machine_id for update;
  select * into c from public.automation_commands where id=p_command_id and machine_id=p_machine_id;
  if not found or c.lease_token is distinct from p_lease_token then
    raise exception 'COMMAND_IDENTITY_CONFLICT' using errcode='22023';
  end if;
  select * into w from public.washing_cycles where id=c.cycle_id;
  select * into o from public.orders where id=w.order_id for update;
  select * into e from public.controller_events where machine_id=p_machine_id and event_id=p_event_id;
  if found then
    if e.command_id<>p_command_id or e.event_type<>p_event_type then
      raise exception 'CONTROLLER_EVENT_CONFLICT' using errcode='22023';
    end if;
    return w;
  end if;
  if w.status='FINISHED' then
    if p_event_type not in ('ACK','STARTED','FINISHED') then
      raise exception 'CYCLE_ALREADY_FINISHED' using errcode='P0001';
    end if;
    -- Evento atrasado não regride ciclo nem afeta eventual reserva seguinte.
  else
    if not exists(select 1 from public.machine_reservations where order_id=o.id
      and machine_id=p_machine_id and released_at is null) then
      raise exception 'RESERVATION_INVALID' using errcode='P0001';
    end if;
    if c.status not in ('DISPATCHED','ACKNOWLEDGED','UNKNOWN') then
      raise exception 'COMMAND_NOT_DISPATCHED' using errcode='P0001';
    end if;
    if p_event_type='FINISHED' and w.started_at is null then
      raise exception 'START_EVIDENCE_REQUIRED' using errcode='P0001';
    end if;
    if p_event_type='HEARTBEAT' and w.started_at is null then
      raise exception 'START_EVIDENCE_REQUIRED' using errcode='P0001';
    end if;
  end if;
  v_now:=clock_timestamp();
  insert into public.controller_events(machine_id,command_id,event_id,event_type)
    values(p_machine_id,p_command_id,p_event_id,p_event_type) returning * into e;
  insert into public.audit_logs(actor_type,actor_id,event_type,entity_type,entity_id,correlation_id)
    values('DEVICE',p_machine_id,'CONTROLLER_'||p_event_type,'CYCLE',w.id,e.id);
  if w.status='FINISHED' then return w; end if;
  if c.status<>'ACKNOWLEDGED' then
    update public.automation_commands set status='ACKNOWLEDGED',acknowledged_at=coalesce(acknowledged_at,v_now)
      where id=c.id;
  end if;
  if p_event_type='STARTED' and w.started_at is null then
    update public.washing_cycles set status='RUNNING',started_at=v_now,last_evidence_at=v_now,
      run_deadline_at=v_now+interval '2 hours' where id=w.id returning * into w;
    update public.orders set status='IN_PROGRESS' where id=o.id;
  elsif p_event_type='HEARTBEAT' and w.status='RUNNING' then
    update public.washing_cycles set last_evidence_at=v_now where id=w.id returning * into w;
  elsif p_event_type='FINISHED' then
    update public.washing_cycles set status='FINISHED',finished_at=v_now,last_evidence_at=v_now
      where id=w.id returning * into w;
    update public.orders set status='COMPLETED' where id=o.id;
    update public.machine_reservations set released_at=v_now where order_id=o.id and released_at is null;
    insert into public.audit_logs(actor_type,event_type,entity_type,entity_id,correlation_id)
      values('BACKEND','ORDER_COMPLETED','ORDER',o.id,e.id);
  end if;
  return w;
end;
$$;

-- Chamada explícita do monitor; não instala serviço ou cron.
create function public.mark_cycle_timeout(p_cycle_id uuid)
returns public.washing_cycles language plpgsql security definer set search_path='' as $$
declare w public.washing_cycles; c public.automation_commands; m uuid; v_now timestamptz;
begin
  select machine_id into m from public.washing_cycles where id=p_cycle_id;
  if not found then raise exception 'CYCLE_NOT_FOUND' using errcode='22023'; end if;
  perform 1 from public.machines where id=m for update;
  select * into w from public.washing_cycles where id=p_cycle_id;
  perform 1 from public.orders where id=w.order_id for update;
  if w.status not in ('PENDING_START','RUNNING') then return w; end if;
  select * into c from public.automation_commands where cycle_id=w.id and command_type='START';
  v_now:=clock_timestamp();
  if (w.status='PENDING_START' and (c.expires_at<=v_now or
      (c.status='DISPATCHED' and c.lease_until<=v_now)))
    or (w.status='RUNNING' and (w.last_evidence_at is null or
      w.last_evidence_at<=v_now-interval '2 minutes' or w.run_deadline_at<=v_now)) then
    update public.washing_cycles set status='UNKNOWN' where id=w.id returning * into w;
    update public.orders set status='NEEDS_REVIEW' where id=w.order_id;
    -- ACK já recebido permanece; a incerteza física é registrada no ciclo.
    if c.status in ('PENDING','DISPATCHED') then
      update public.automation_commands set status=case when c.status='PENDING' then 'EXPIRED' else 'UNKNOWN' end where id=c.id;
    end if;
    insert into public.audit_logs(actor_type,event_type,entity_type,entity_id,correlation_id)
      values('SYSTEM','CYCLE_TIMEOUT','CYCLE',w.id,w.id);
  end if;
  return w;
end;
$$;
revoke all on function public.claim_start_command(uuid),
 public.record_controller_event(uuid,uuid,uuid,uuid,text),public.mark_cycle_timeout(uuid)
 from public,anon,authenticated;
grant execute on function public.claim_start_command(uuid),
 public.record_controller_event(uuid,uuid,uuid,uuid,text),public.mark_cycle_timeout(uuid)
 to service_role;
commit;
