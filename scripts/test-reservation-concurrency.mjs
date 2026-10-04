import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { Client } from 'pg';

// Não imprime credenciais. Por padrão obtém a URL da stack local pela CLI fixada.
let connectionString = process.env.LAVAGO_TEST_DATABASE_URL;
if (!connectionString) {
  try {
    const status = JSON.parse(execFileSync(process.execPath,
      ['node_modules/supabase/dist/supabase.js', 'status', '-o', 'json'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 15000 }));
    connectionString = status.DB_URL;
  } catch {
    throw new Error('Não foi possível obter a URL local. Inicie a stack e verifique a CLI.');
  }
}
let url;
try { url = new URL(connectionString); }
catch { throw new Error('URL de teste local ausente ou inválida'); }
assert(['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname), 'Teste permitido apenas em loopback');
assert.equal(url.port, '54322', 'Use somente a porta do banco local LavaGo');
const clients = Array.from({ length: 3 }, () => new Client({
  connectionString, connectionTimeoutMillis: 5000, statement_timeout: 10000,
}));
const [admin, a, b] = clients;
const connected = new Set();
const users = [randomUUID(), randomUUID()];
const machines = [randomUUID(), randomUUID(), randomUUID()];
const provider = `test-${randomUUID()}`;
const service = randomUUID();
const reserve = (client, user, machine, key) => client.query(
  'select id from public.create_order($1,$2,$3,$4)', [user, machine, service, key]);

async function race(machine, sameKey) {
  await a.query('begin');
  await b.query('begin');
  await a.query('set local role service_role');
  await b.query('set local role service_role');
  const key = randomUUID();
  const first = await reserve(a, users[0], machine, key);
  const pid = (await b.query('select pg_backend_pid() as pid')).rows[0].pid;
  const second = reserve(b, sameKey ? users[0] : users[1], machine, sameKey ? key : randomUUID())
    .then(result => ({ result }), error => ({ error }));
  // Confirma bloqueio real; não infere concorrência apenas pela duração do teste.
  let blocked = false;
  for (let i = 0; i < 100; i++) {
    const state = await admin.query('select wait_event_type from pg_stat_activity where pid=$1', [pid]);
    if (state.rows[0]?.wait_event_type === 'Lock') { blocked = true; break; }
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  if (!blocked) {
    await a.query('rollback');
    await second;
    throw new Error('A segunda conexão não aguardou o bloqueio esperado');
  }
  await a.query('commit');
  const outcome = await second;
  if (sameKey) {
    assert.ifError(outcome.error);
    assert.equal(outcome.result.rows[0].id, first.rows[0].id);
    await b.query('commit');
  } else {
    assert.equal(outcome.error?.code, 'P0001');
    assert.equal(outcome.error?.message, 'MACHINE_RESERVED');
    await b.query('rollback');
  }
  const counts = await admin.query(`select
    (select count(*)::int from public.orders where machine_id=$1) as orders,
    (select count(*)::int from public.machine_reservations where machine_id=$1 and released_at is null) as reservations`, [machine]);
  assert.deepEqual(counts.rows[0], { orders: 1, reservations: 1 });
  return first.rows[0].id;
}

async function paymentRace(order, mode) {
  await a.query('begin');
  await b.query('begin');
  await a.query('set local role service_role');
  await b.query('set local role service_role');
  const payment = randomUUID();
  const pay = (client, event) => client.query(
    'select status from public.record_verified_payment($1,$2,$3,$4,2500,\'BRL\')',
    [order, provider, payment, event]);
  const cancel = client => client.query('select status from public.cancel_order($1,$2)', [users[0], order]);
  if (mode === 'cancel-before') await cancel(a);
  else await pay(a, randomUUID());
  const pid = (await b.query('select pg_backend_pid() as pid')).rows[0].pid;
  const pending = (mode === 'cancel-after' ? cancel(b) : pay(b, randomUUID()))
    .then(result => ({ result }), error => ({ error }));
  let blocked = false;
  for (let i = 0; i < 100; i++) {
    const state = await admin.query('select wait_event_type from pg_stat_activity where pid=$1', [pid]);
    if (state.rows[0]?.wait_event_type === 'Lock') { blocked = true; break; }
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  if (!blocked) {
    await a.query('rollback'); await pending;
    throw new Error('Corrida financeira não aguardou lock');
  }
  await a.query('commit');
  const outcome = await pending;
  assert.ifError(outcome.error);
  assert.equal(outcome.result.rows[0].status, mode === 'cancel-before' ? 'CANCELLED' : 'AUTHORIZED');
  await b.query('commit');
  const counts = (await admin.query(`select
    (select count(*)::int from public.payments where order_id=$1) as payments,
    (select count(*)::int from public.washing_cycles where order_id=$1) as cycles,
    (select count(*)::int from public.automation_commands c join public.washing_cycles w on w.id=c.cycle_id where w.order_id=$1) as commands,
    (select count(*)::int from public.machine_reservations where order_id=$1 and released_at is null) as reservations`, [order])).rows[0];
  assert.deepEqual(counts, { payments: 1, cycles: mode === 'cancel-before' ? 0 : 1,
    commands: mode === 'cancel-before' ? 0 : 1, reservations: mode === 'cancel-before' ? 0 : 1 });
}

try {
  for (const client of clients) { await client.connect(); connected.add(client); }
  await admin.query('insert into auth.users(id) values ($1),($2)', users);
  for (const machine of machines) {
    await admin.query(`insert into public.machines(id,code,label,operational_status,last_seen_at)
      values ($1,$2,'Teste concorrência','ACTIVE',clock_timestamp())`, [machine, `test-${machine}`]);
  }
  await admin.query("insert into public.services(id,name,price_cents,active) values ($1,'Teste concorrência',2500,true)", [service]);
  for (const machine of machines) await admin.query('insert into public.machine_services values($1,$2)', [machine, service]);
  const firstOrder = await race(machines[0], false);
  console.log('PASS: duas solicitações concorrentes, somente uma reserva');
  const secondOrder = await race(machines[1], true);
  console.log('PASS: retries concorrentes retornam o mesmo pedido');
  await paymentRace(firstOrder, 'events');
  console.log('PASS: eventos concorrentes da mesma cobrança geram um único START');
  await paymentRace(secondOrder, 'cancel-after');
  console.log('PASS: aprovação vence a corrida e cancelamento preserva reserva');
  const thirdOrder = (await reserve(admin, users[0], machines[2], randomUUID())).rows[0].id;
  await paymentRace(thirdOrder, 'cancel-before');
  console.log('PASS: cancelamento vence a corrida e pagamento não autoriza máquina');
} catch (error) {
  console.error('FAIL:', error.code ?? error.message);
  process.exitCode = 1;
} finally {
  await Promise.all([a, b].filter(c => connected.has(c)).map(c => c.query('rollback').catch(() => {})));
  try {
    if (!connected.has(admin)) throw new Error('Sem conexão para limpeza');
    await admin.query('begin');
    await admin.query('delete from public.audit_logs where correlation_id in (select id from public.payment_webhook_events where provider=$1)', [provider]);
    await admin.query('delete from public.payment_webhook_events where provider=$1', [provider]);
    await admin.query('delete from public.payments where provider=$1', [provider]);
    await admin.query('delete from public.automation_commands where machine_id=any($1::uuid[])', [machines]);
    await admin.query('delete from public.washing_cycles where machine_id=any($1::uuid[])', [machines]);
    await admin.query('delete from public.machine_reservations where machine_id=any($1::uuid[])', [machines]);
    await admin.query('delete from public.orders where machine_id=any($1::uuid[])', [machines]);
    await admin.query('delete from public.machine_services where machine_id=any($1::uuid[])', [machines]);
    await admin.query('delete from public.machines where id=any($1::uuid[])', [machines]);
    await admin.query('delete from public.services where id=$1', [service]);
    await admin.query('delete from public.profiles where id=any($1::uuid[])', [users]);
    await admin.query('delete from auth.users where id=any($1::uuid[])', [users]);
    await admin.query('commit');
  } catch {
    if (connected.has(admin)) await admin.query('rollback').catch(() => {});
    console.error('Falha na limpeza das fixtures locais de concorrência.');
    process.exitCode = 1;
  }
  await Promise.all([...connected].map(c => c.end().catch(() => {})));
}
