begin;
create extension if not exists pgtap with schema extensions;
select plan(25);
insert into auth.users(id) values('13000000-0000-0000-0000-000000000001');
insert into public.services(id,name,price_cents,active)
 values('33000000-0000-0000-0000-000000000001','Pagamento teste',2500,true);
create temporary table payment_orders(n integer primary key, id uuid);
do $$
declare i integer; m uuid; o uuid;
begin
  for i in 1..7 loop
    insert into public.machines(code,label,operational_status,last_seen_at)
      values('PAY-AUTH-'||i,'Teste','ACTIVE',clock_timestamp()) returning id into m;
    insert into public.machine_services values(m,'33000000-0000-0000-0000-000000000001');
    select id into o from public.create_order('13000000-0000-0000-0000-000000000001',
      m,'33000000-0000-0000-0000-000000000001',gen_random_uuid());
    insert into payment_orders values(i,o);
  end loop;
end;
$$;
grant select on payment_orders to service_role;
set local role service_role;
select is((public.record_verified_payment((select id from payment_orders where n=1),
 'test','pay-1','evt-1',2500,'BRL')).status,'AUTHORIZED','pagamento válido autoriza pedido');
select is((select count(*) from public.washing_cycles where order_id=(select id from payment_orders where n=1)),
 1::bigint,'um ciclo criado');
select is((select count(*) from public.automation_commands),1::bigint,'um START persistido');
select is((select count(*) from public.audit_logs where correlation_id=(select id from public.payment_webhook_events
 where provider='test' and provider_event_id='evt-1')),5::bigint,'transação registra cinco eventos de auditoria');
select is((public.record_verified_payment((select id from payment_orders where n=1),
 'test','pay-1','evt-1',2500,'BRL')).status,'AUTHORIZED','evento repetido é idempotente');
select is((select count(*) from public.audit_logs),5::bigint,'retry não duplica auditoria');
select is((public.record_verified_payment((select id from payment_orders where n=1),
 'test','pay-1','evt-2',2500,'BRL')).status,'AUTHORIZED','outro evento da cobrança não reautoriza');
select public.record_verified_payment((select id from payment_orders where n=1),'test','pay-extra','evt-extra',2500,'BRL');
select is((select reconciliation_reason from public.payments where provider_payment_id='pay-extra'),
 'EXTRA_PAYMENT','segunda cobrança exige revisão');
select is((select count(*) from public.automation_commands),1::bigint,'segunda cobrança não gera START extra');
select throws_ok($$select public.record_verified_payment((select id from payment_orders where n=1),
 'test','pay-1','evt-3',1,'BRL')$$,'22023','PAYMENT_IDENTITY_CONFLICT','cobrança não muda valor');
select throws_ok($$select public.record_verified_payment((select id from payment_orders where n=2),
 'test','pay-2','evt-1',2500,'BRL')$$,'22023','EVENT_IDENTITY_CONFLICT','evento não muda de cobrança');
select is((public.record_verified_payment((select id from payment_orders where n=2),
 'test','pay-2','evt-mismatch',1,'BRL')).status,'NEEDS_REVIEW','divergência financeira exige revisão');
select is((select count(*) from public.washing_cycles where order_id=(select id from payment_orders where n=2)),
 0::bigint,'divergência não cria ciclo');
reset role;
update public.orders set created_at=clock_timestamp()-interval '20 minutes',expires_at=clock_timestamp()-interval '10 minutes'
 where id=(select id from payment_orders where n=3);
set local role service_role;
select is((public.record_verified_payment((select id from payment_orders where n=3),
 'test','pay-3','evt-late',2500,'BRL')).status,'NEEDS_REVIEW','pagamento tardio exige revisão');
select public.cancel_order('13000000-0000-0000-0000-000000000001',(select id from payment_orders where n=4));
select is((public.record_verified_payment((select id from payment_orders where n=4),
 'test','pay-4','evt-cancelled',2500,'BRL')).status,'CANCELLED','pagamento não ressuscita pedido cancelado');
reset role;
update public.machines set operational_status='MAINTENANCE' where id=(select machine_id from public.orders
 where id=(select id from payment_orders where n=5));
update public.machine_reservations set released_at=clock_timestamp() where order_id=(select id from payment_orders where n=6);
set local role service_role;
select is((public.record_verified_payment((select id from payment_orders where n=5),
 'test','pay-5','evt-maintenance',2500,'BRL')).status,'NEEDS_REVIEW','manutenção impede autorização');
select is((public.record_verified_payment((select id from payment_orders where n=6),
 'test','pay-6','evt-reservation',2500,'BRL')).status,'NEEDS_REVIEW','reserva liberada impede autorização');
set local role authenticated;
select throws_ok($$select public.record_verified_payment(null,'test','x','x',2500,'BRL')$$,
 '42501',null,'cliente não confirma pagamento');
set local role anon;
select throws_ok($$select public.record_verified_payment(null,'test','x','x',2500,'BRL')$$,
 '42501',null,'anônimo não confirma pagamento');
reset role;
-- Injeta falha no último estágio da transação: prova rollback de todos os efeitos.
create function pg_temp.fail_command() returns trigger language plpgsql as $$
begin raise exception 'TEST_COMMAND_FAILURE'; end; $$;
create trigger test_fail_command before insert on public.automation_commands
 for each row execute function pg_temp.fail_command();
set local role service_role;
select throws_ok($$select public.record_verified_payment((select id from payment_orders where n=7),
 'test','pay-7','evt-rollback',2500,'BRL')$$,'P0001','TEST_COMMAND_FAILURE','falha no comando aborta operação inteira');
select is((select count(*) from public.payments where provider_payment_id='pay-7'),0::bigint,'pagamento revertido');
select is((select count(*) from public.payment_webhook_events where provider_event_id='evt-rollback'),0::bigint,'evento revertido');
select is((select status from public.orders where id=(select id from payment_orders where n=7)),
 'WAITING_PAYMENT','autorização revertida');
select is((select count(*) from public.washing_cycles where order_id=(select id from payment_orders where n=7)),0::bigint,'ciclo revertido');
reset role;
drop trigger test_fail_command on public.automation_commands;
set local role service_role;
select is((public.record_verified_payment((select id from payment_orders where n=7),
 'test','pay-7','evt-rollback',2500,'BRL')).status,'AUTHORIZED','retry após falha conclui operação');
reset role;
select * from finish();
rollback;
