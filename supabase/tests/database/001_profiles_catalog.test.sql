begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id) values
 ('10000000-0000-0000-0000-000000000001'),
 ('10000000-0000-0000-0000-000000000002');
select is((select count(*) from public.profiles where id in
 ('10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002')), 2::bigint,
 'trigger cria perfis');
insert into public.machines (id, code, label, operational_status) values
 ('20000000-0000-0000-0000-000000000001', 'TEST-A', 'Teste ativo', 'ACTIVE'),
 ('20000000-0000-0000-0000-000000000002', 'TEST-B', 'Teste oculto', 'DISABLED');
insert into public.services (id, name, price_cents, active) values
 ('30000000-0000-0000-0000-000000000001', 'Teste ativo', 1000, true),
 ('30000000-0000-0000-0000-000000000002', 'Teste inativo', 1000, false);
insert into public.machine_services values
 ('20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002');

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select is((select count(*) from public.profiles), 1::bigint, 'A lê somente seu perfil');
select lives_ok($$update public.profiles set display_name = 'Cliente A'
 where id = '10000000-0000-0000-0000-000000000001'$$, 'A altera próprio nome');
select lives_ok($$update public.profiles set display_name = 'Intruso'
 where id = '10000000-0000-0000-0000-000000000002'$$,
 'tentativa de A alterar B é filtrada pela RLS; integridade verificada como B abaixo');
select throws_ok($$update public.profiles set id = '10000000-0000-0000-0000-000000000003'$$,
 '42501', null, 'cliente não altera identidade');
select throws_ok($$update public.services set price_cents = 1$$,
 '42501', null, 'cliente não altera preço');
select throws_ok($$update public.machines set operational_status = 'ACTIVE'$$,
 '42501', null, 'cliente não altera máquina');
select is((select count(*) from public.machines where code like 'TEST-%'), 1::bigint,
 'máquina desabilitada oculta');
select is((select count(*) from public.services where id in
 ('30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002')), 1::bigint,
 'serviço inativo oculto');
select is((select count(*) from public.machine_services where machine_id in
 ('20000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002')), 1::bigint,
 'associações ocultas não vazam');
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select is((select display_name from public.profiles), '', 'B permanece intacto e só lê seu perfil');
set local role anon;
select throws_ok($$select * from public.profiles$$, '42501', null, 'anônimo não lê perfis');
select throws_ok($$select * from public.machines$$, '42501', null, 'anônimo não lê catálogo');
reset role;
select * from finish();
rollback;
