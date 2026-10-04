begin;
create extension if not exists pgtap with schema extensions;
select plan(22);
insert into auth.users(id) values
 ('11000000-0000-0000-0000-000000000001'), ('11000000-0000-0000-0000-000000000002');
insert into public.machines(id, code, label, operational_status, last_seen_at) values
 ('21000000-0000-0000-0000-000000000001', 'ORDER-TEST-1', 'Teste', 'ACTIVE', clock_timestamp()),
 ('21000000-0000-0000-0000-000000000002', 'ORDER-TEST-2', 'Offline', 'ACTIVE', null);
insert into public.services(id, name, price_cents, active) values
 ('31000000-0000-0000-0000-000000000001', 'Serviço teste', 2500, true);
insert into public.machine_services values
 ('21000000-0000-0000-0000-000000000001', '31000000-0000-0000-0000-000000000001');
create temporary table result_order(id uuid);
grant all on result_order to service_role;
set local role service_role;
insert into result_order select id from public.create_order(
 '11000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001',
 '31000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000001');
select is((select price_cents from public.orders where id = (select id from result_order)), 2500, 'preço vem do catálogo');
select is((select expires_at - created_at from public.orders where id = (select id from result_order)), interval '10 minutes', 'prazo definido no servidor');
select is((select id from public.create_order(
 '11000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001',
 '31000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000001')),
 (select id from result_order), 'retry retorna mesmo pedido');
select throws_ok($$select public.create_order(
 '11000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000002',
 '31000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000001')$$,
 '22023', 'IDEMPOTENCY_CONFLICT', 'chave não pode mudar conteúdo');
select throws_ok($$select public.create_order(
 '11000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000001',
 '31000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002')$$,
 'P0001', 'MACHINE_RESERVED', 'segundo pedido bloqueado');
select throws_ok($$select public.create_order(
 '11000000-0000-0000-0000-000000000002', '21000000-0000-0000-0000-000000000002',
 '31000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002')$$,
 'P0001', 'MACHINE_OFFLINE', 'offline não recebe reserva');
select throws_ok($$update public.orders set price_cents = 1$$, '42501', null, 'backend também usa funções para escrita');
select is((public.expire_order((select id from result_order))).status, 'WAITING_PAYMENT', 'não expira cedo');
select throws_ok($$select public.cancel_order('11000000-0000-0000-0000-000000000002', (select id from result_order))$$,
 '22023', 'ORDER_NOT_FOUND', 'cancelamento exige dono correto');
reset role;
grant select on result_order to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11000000-0000-0000-0000-000000000001', true);
select is((select count(*) from public.orders), 1::bigint, 'A lê seu pedido');
select throws_ok($$update public.orders set status = 'CANCELLED'$$, '42501', null, 'cliente não altera pedido');
select throws_ok($$select * from public.machine_reservations$$, '42501', null, 'reservas internas não expostas');
select throws_ok($$select public.create_order(null, null, null, null)$$, '42501', null, 'cliente não chama RPC privilegiada');
select set_config('request.jwt.claim.sub', '11000000-0000-0000-0000-000000000002', true);
select is((select count(*) from public.orders), 0::bigint, 'B não lê pedido de A');
set local role anon;
select throws_ok($$select * from public.orders$$, '42501', null, 'anônimo bloqueado');
set local role service_role;
select is((public.cancel_order('11000000-0000-0000-0000-000000000001', (select id from result_order))).status,
 'CANCELLED', 'cancela pedido pendente');
select is((select count(*) from public.machine_reservations where order_id = (select id from result_order) and released_at is null),
 0::bigint, 'cancelamento libera reserva');
select is((public.cancel_order('11000000-0000-0000-0000-000000000001', (select id from result_order))).status,
 'CANCELLED', 'cancelamento idempotente');
select is((select status from public.create_order(
 '11000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001',
 '31000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000001')),
 'CANCELLED', 'retry não ressuscita pedido');
truncate result_order;
insert into result_order select id from public.create_order(
 '11000000-0000-0000-0000-000000000001', '21000000-0000-0000-0000-000000000001',
 '31000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000002');
reset role;
-- Relógio simulado somente na fixture, com papel postgres.
update public.orders set created_at = clock_timestamp() - interval '20 minutes',
 expires_at = clock_timestamp() - interval '10 minutes' where id = (select id from result_order);
set local role service_role;
select is((public.expire_order((select id from result_order))).status, 'EXPIRED', 'expira pedido vencido');
select is((select count(*) from public.machine_reservations where order_id = (select id from result_order) and released_at is null),
 0::bigint, 'expiração libera reserva');
select is((public.expire_order((select id from result_order))).status, 'EXPIRED', 'expiração idempotente');
reset role;
select * from finish();
rollback;
