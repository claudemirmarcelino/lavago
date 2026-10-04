begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
insert into auth.users(id) values('14000000-0000-0000-0000-000000000001');
insert into public.services(id,name,price_cents,active)
 values('34000000-0000-0000-0000-000000000001','Simulação',2500,true);
create temporary table cycle_cases(n integer primary key,machine uuid,order_id uuid,cycle uuid,command uuid,token uuid);
do $$
declare i integer; m uuid; o uuid;
begin
 for i in 1..4 loop
  insert into public.machines(code,label,operational_status,last_seen_at)
   values('CYCLE-SIM-'||i,'Simulador','ACTIVE',clock_timestamp()) returning id into m;
  insert into public.machine_services values(m,'34000000-0000-0000-0000-000000000001');
  select id into o from public.create_order('14000000-0000-0000-0000-000000000001',m,
   '34000000-0000-0000-0000-000000000001',gen_random_uuid());
  perform public.record_verified_payment(o,'simulation','cycle-pay-'||i,'cycle-evt-'||i,2500,'BRL');
  insert into cycle_cases select i,m,o,w.id,a.id,null from public.washing_cycles w
   join public.automation_commands a on a.cycle_id=w.id where w.order_id=o;
 end loop;
end;
$$;
grant all on cycle_cases to service_role;
set local role service_role;
update cycle_cases set token=(public.claim_start_command(machine)).lease_token where n in (1,2,4);
select is((select status from public.automation_commands where id=(select command from cycle_cases where n=1)),
 'DISPATCHED','comando entregue com posse');
select ok((select token is not null from cycle_cases where n=1),'token de entrega gerado');
select ok((public.claim_start_command((select machine from cycle_cases where n=1))).id is null,'não reenvia START entregue');
select throws_ok($$select public.record_controller_event(machine,command,gen_random_uuid(),gen_random_uuid(),'ACK')
 from cycle_cases where n=1$$,'22023','COMMAND_IDENTITY_CONFLICT','token errado rejeitado');
select throws_ok($$select public.record_controller_event(gen_random_uuid(),command,token,gen_random_uuid(),'ACK')
 from cycle_cases where n=1$$,'22023','COMMAND_IDENTITY_CONFLICT','máquina errada rejeitada');
select throws_ok($$select public.record_controller_event(machine,command,token,gen_random_uuid(),'FINISHED')
 from cycle_cases where n=1$$,'P0001','START_EVIDENCE_REQUIRED','fim antes do início rejeitado');
select is((select (public.record_controller_event(machine,command,token,
 '44000000-0000-0000-0000-000000000001','ACK')).status from cycle_cases where n=1),
 'PENDING_START','ACK não significa início físico');
select is((select (public.record_controller_event(machine,command,token,
 '44000000-0000-0000-0000-000000000001','ACK')).status from cycle_cases where n=1),
 'PENDING_START','ACK duplicado idempotente');
select throws_ok($$select public.record_controller_event(machine,command,token,
 '44000000-0000-0000-0000-000000000001','STARTED') from cycle_cases where n=1$$,
 '22023','CONTROLLER_EVENT_CONFLICT','ID de evento não muda de conteúdo');
select is((select (public.record_controller_event(machine,command,token,
 '44000000-0000-0000-0000-000000000002','STARTED')).status from cycle_cases where n=1),
 'RUNNING','evidência de início inicia ciclo');
select is((select status from public.orders where id=(select order_id from cycle_cases where n=1)),
 'IN_PROGRESS','pedido acompanha execução');
select is((select (public.record_controller_event(machine,command,token,gen_random_uuid(),'HEARTBEAT')).status
 from cycle_cases where n=1),'RUNNING','heartbeat de ciclo aceito');
select is((public.mark_cycle_timeout((select cycle from cycle_cases where n=1))).status,'RUNNING','não expira ciclo saudável');
select is((select (public.record_controller_event(machine,command,token,
 '44000000-0000-0000-0000-000000000003','FINISHED')).status from cycle_cases where n=1),
 'FINISHED','fim confirmado conclui ciclo');
select is((select status from public.orders where id=(select order_id from cycle_cases where n=1)),
 'COMPLETED','pedido concluído');
select is((select count(*) from public.machine_reservations where order_id=(select order_id from cycle_cases where n=1)
 and released_at is null),0::bigint,'libera reserva após fim');
select is((select (public.record_controller_event(machine,command,token,
 '44000000-0000-0000-0000-000000000003','FINISHED')).status from cycle_cases where n=1),
 'FINISHED','fim duplicado idempotente');
select is((select (public.record_controller_event(machine,command,token,gen_random_uuid(),'STARTED')).status
 from cycle_cases where n=1),'FINISHED','início atrasado não reabre ciclo');
reset role;
update public.automation_commands set lease_until=clock_timestamp()-interval '1 second'
 where id=(select command from cycle_cases where n=2);
update public.automation_commands set created_at=clock_timestamp()-interval '5 minutes',
 expires_at=clock_timestamp()-interval '1 minute' where id=(select command from cycle_cases where n=3);
set local role service_role;
select is((public.mark_cycle_timeout((select cycle from cycle_cases where n=2))).status,'UNKNOWN','entrega sem ACK vira incerta');
select ok((public.claim_start_command((select machine from cycle_cases where n=2))).id is null,'não reenvia comando incerto');
select is((select count(*) from public.machine_reservations where order_id=(select order_id from cycle_cases where n=2)
 and released_at is null),1::bigint,'timeout preserva reserva');
select is((public.mark_cycle_timeout((select cycle from cycle_cases where n=2))).status,'UNKNOWN','timeout repetido idempotente');
select is((select (public.record_controller_event(machine,command,token,gen_random_uuid(),'STARTED')).status
 from cycle_cases where n=2),'RUNNING','início físico tardio reconcilia entrega incerta');
select is((public.mark_cycle_timeout((select cycle from cycle_cases where n=3))).status,'UNKNOWN','comando vencido bloqueia revisão');
select is((select status from public.automation_commands where id=(select command from cycle_cases where n=3)),
 'EXPIRED','comando não entregue expira');
select public.record_controller_event(machine,command,token,gen_random_uuid(),'STARTED') from cycle_cases where n=4;
reset role;
update public.washing_cycles set last_evidence_at=clock_timestamp()-interval '3 minutes'
 where id=(select cycle from cycle_cases where n=4);
set local role service_role;
select is((public.mark_cycle_timeout((select cycle from cycle_cases where n=4))).status,'UNKNOWN','perda de heartbeat bloqueia ciclo');
select is((select (public.record_controller_event(machine,command,token,gen_random_uuid(),'HEARTBEAT')).status
 from cycle_cases where n=4),'UNKNOWN','heartbeat sozinho não resolve incerteza');
select is((select (public.record_controller_event(machine,command,token,gen_random_uuid(),'FINISHED')).status
 from cycle_cases where n=4),'FINISHED','fim físico confirmado resolve ciclo incerto');
set local role authenticated;
select throws_ok($$select public.claim_start_command(null)$$,'42501',null,'cliente não recebe comando');
select throws_ok($$select public.record_controller_event(null,null,null,null,'ACK')$$,'42501',null,'cliente não forja evidência');
select throws_ok($$select * from public.controller_events$$,'42501',null,'eventos de controle privados');
set local role anon;
select throws_ok($$select public.mark_cycle_timeout(null)$$,'42501',null,'anônimo não altera ciclo');
reset role;
select * from finish();
rollback;
