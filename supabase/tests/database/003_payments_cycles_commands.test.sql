begin;
create extension if not exists pgtap with schema extensions;
select plan(28);
insert into auth.users(id) values
 ('12000000-0000-0000-0000-000000000001'), ('12000000-0000-0000-0000-000000000002');
insert into public.machines(id,code,label,operational_status,last_seen_at) values
 ('22000000-0000-0000-0000-000000000001','FIN-TEST-1','Teste','ACTIVE',clock_timestamp()),
 ('22000000-0000-0000-0000-000000000002','FIN-TEST-2','Teste','ACTIVE',clock_timestamp());
insert into public.services(id,name,price_cents,active) values
 ('32000000-0000-0000-0000-000000000001','Teste',2500,true);
insert into public.machine_services values
 ('22000000-0000-0000-0000-000000000001','32000000-0000-0000-0000-000000000001');
create temporary table fin_order as select id from public.create_order(
 '12000000-0000-0000-0000-000000000001','22000000-0000-0000-0000-000000000001',
 '32000000-0000-0000-0000-000000000001','42000000-0000-0000-0000-000000000001');
grant select on fin_order to service_role;
insert into public.payments(id,order_id,provider,provider_payment_id,amount_cents,currency)
 select '52000000-0000-0000-0000-000000000001',id,'test','payment-1',2500,'BRL' from fin_order;
insert into public.washing_cycles(id,order_id,machine_id)
 select '62000000-0000-0000-0000-000000000001',id,'22000000-0000-0000-0000-000000000001' from fin_order;
insert into public.automation_commands(id,cycle_id,machine_id,expires_at) values
 ('72000000-0000-0000-0000-000000000001','62000000-0000-0000-0000-000000000001',
 '22000000-0000-0000-0000-000000000001',clock_timestamp()+interval '1 minute');
insert into public.payment_webhook_events(provider,provider_event_id) values('test','event-1');

select throws_ok($$insert into public.payments(order_id,provider,provider_payment_id,amount_cents,currency)
 select id,'test','payment-1',2500,'BRL' from fin_order$$, '23505', null, 'cobrança externa única');
select throws_ok($$update public.payments set amount_cents=0$$, '23514', null, 'valor deve ser positivo');
select throws_ok($$update public.payments set status='APPROVED'$$, '23514', null, 'aprovação requer confirmação registrada');
select throws_ok($$update public.washing_cycles set machine_id='22000000-0000-0000-0000-000000000002'$$,
 '23503', null, 'máquina do ciclo deve corresponder ao pedido');
select throws_ok($$insert into public.washing_cycles(order_id,machine_id)
 select id,'22000000-0000-0000-0000-000000000001' from fin_order$$, '23505', null, 'um ciclo por pedido');
select throws_ok($$update public.washing_cycles set status='RUNNING'$$, '23514', null, 'execução exige início registrado');
select throws_ok($$insert into public.automation_commands(cycle_id,machine_id,expires_at) values
 ('62000000-0000-0000-0000-000000000001','22000000-0000-0000-0000-000000000001',clock_timestamp()+interval '1 minute')$$,
 '23505', null, 'um START por ciclo');
select throws_ok($$update public.automation_commands set machine_id='22000000-0000-0000-0000-000000000002'$$,
 '23503', null, 'comando não muda destinatário do ciclo');
select throws_ok($$update public.automation_commands set expires_at=created_at$$,
 '23514', null, 'prazo do comando positivo');
select throws_ok($$insert into public.payment_webhook_events(provider,provider_event_id) values('test','event-1')$$,
 '23505', null, 'webhook duplicado bloqueado');
select throws_ok($$update public.payment_webhook_events set processing_status='PROCESSED'$$,
 '23514', null, 'processamento exige data de conclusão');

set local role authenticated;
select set_config('request.jwt.claim.sub','12000000-0000-0000-0000-000000000001',true);
select is((select count(*) from public.payments),1::bigint,'A lê seu pagamento');
select is((select count(*) from public.washing_cycles),1::bigint,'A lê seu ciclo');
select throws_ok($$update public.payments set status='APPROVED',confirmed_at=clock_timestamp()$$,
 '42501',null,'cliente não aprova pagamento');
select throws_ok($$select * from public.automation_commands$$,'42501',null,'comandos privados');
select throws_ok($$select * from public.payment_webhook_events$$,'42501',null,'webhooks privados');
select throws_ok($$select * from public.audit_logs$$,'42501',null,'auditoria privada');
select set_config('request.jwt.claim.sub','12000000-0000-0000-0000-000000000002',true);
select is((select count(*) from public.payments),0::bigint,'B não lê pagamento de A');
select is((select count(*) from public.washing_cycles),0::bigint,'B não lê ciclo de A');
set local role anon;
select throws_ok($$select * from public.payments$$,'42501',null,'anônimo bloqueado');
set local role service_role;
select throws_ok($$update public.payments set status='APPROVED',confirmed_at=clock_timestamp()$$,
 '42501',null,'backend sem DML financeiro direto neste incremento');
select throws_ok($$select public.cancel_order('12000000-0000-0000-0000-000000000001',(select id from fin_order))$$,
 'P0001','ORDER_REQUIRES_RECONCILIATION','cancelamento financeiro bloqueado');
reset role;
update public.orders set created_at=clock_timestamp()-interval '20 minutes',
 expires_at=clock_timestamp()-interval '10 minutes' where id=(select id from fin_order);
set local role service_role;
select throws_ok($$select public.expire_order((select id from fin_order))$$,
 'P0001','ORDER_REQUIRES_RECONCILIATION','expiração financeira bloqueada');
select is((select count(*) from public.machine_reservations where order_id=(select id from fin_order)
 and released_at is null),1::bigint,'reserva preservada após falha de liberação');
reset role;
update public.automation_commands set status='ACKNOWLEDGED',acknowledged_at=clock_timestamp();
select is((select status from public.washing_cycles where id='62000000-0000-0000-0000-000000000001'),
 'PENDING_START','ACK não inicia ciclo');
select throws_ok($$update public.automation_commands set attempts=-1$$,'23514',null,'tentativas não negativas');
delete from public.automation_commands where cycle_id='62000000-0000-0000-0000-000000000001';
delete from public.washing_cycles where id='62000000-0000-0000-0000-000000000001';
select throws_ok($$select public.expire_order((select id from fin_order))$$,
 'P0001','ORDER_REQUIRES_RECONCILIATION','pagamento sozinho bloqueia expiração');
delete from public.payments where id='52000000-0000-0000-0000-000000000001';
insert into public.washing_cycles(id,order_id,machine_id,status)
 select '62000000-0000-0000-0000-000000000001',id,'22000000-0000-0000-0000-000000000001','UNKNOWN' from fin_order;
select throws_ok($$select public.cancel_order('12000000-0000-0000-0000-000000000001',(select id from fin_order))$$,
 'P0001','ORDER_REQUIRES_RECONCILIATION','ciclo incerto sozinho bloqueia liberação');
select * from finish();
rollback;
