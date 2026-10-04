import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { Client } from 'pg';
import { localDatabaseUrl } from './lib/local-database.mjs';

const db = new Client({ connectionString: localDatabaseUrl(), connectionTimeoutMillis: 5000, statement_timeout: 10000 });
let connected = false;
try {
  await db.connect(); connected = true;
  await db.query('begin');
  const user = randomUUID(), service = randomUUID();
  await db.query('insert into auth.users(id) values($1)', [user]);
  await db.query("insert into public.services(id,name,price_cents,active) values($1,'Simulação local',2500,true)", [service]);
  for (const scenario of ['normal', 'timeout']) {
    await db.query('reset role');
    const machine = randomUUID();
    await db.query(`insert into public.machines(id,code,label,operational_status,last_seen_at)
      values($1,$2,'Controlador simulado','ACTIVE',clock_timestamp())`, [machine, `sim-${machine}`]);
    await db.query('insert into public.machine_services values($1,$2)', [machine, service]);
    await db.query('set local role service_role');
    const order = (await db.query('select * from public.create_order($1,$2,$3,$4)', [user,machine,service,randomUUID()])).rows[0];
    await db.query("select public.record_verified_payment($1,'simulation',$2,$3,2500,'BRL')", [order.id,randomUUID(),randomUUID()]);
    const command = (await db.query('select * from public.claim_start_command($1)', [machine])).rows[0];
    assert(command.lease_token);
    const event = async kind => (await db.query('select * from public.record_controller_event($1,$2,$3,$4,$5)',
      [machine,command.id,command.lease_token,randomUUID(),kind])).rows[0];
    if (scenario === 'normal') {
      assert.equal((await event('ACK')).status, 'PENDING_START');
      assert.equal((await event('STARTED')).status, 'RUNNING');
      assert.equal((await event('FINISHED')).status, 'FINISHED');
      const reservation = await db.query('select count(*)::int as n from public.machine_reservations where order_id=$1 and released_at is null', [order.id]);
      assert.equal(reservation.rows[0].n, 0);
      console.log('PASS: pedido → pagamento simulado → entrega → ACK → início → fim → máquina liberada');
    } else {
      await db.query('reset role');
      await db.query("update public.automation_commands set lease_until=clock_timestamp()-interval '1 second' where id=$1", [command.id]);
      await db.query('set local role service_role');
      const cycle = (await db.query('select * from public.mark_cycle_timeout($1)', [command.cycle_id])).rows[0];
      assert.equal(cycle.status, 'UNKNOWN');
      const reservation = await db.query('select count(*)::int as n from public.machine_reservations where order_id=$1 and released_at is null', [order.id]);
      assert.equal(reservation.rows[0].n, 1);
      console.log('PASS: entrega sem confirmação → timeout → estado incerto → reserva preservada');
    }
  }
} catch (error) { console.error('FAIL:', error.code ?? error.message); process.exitCode = 1; }
finally {
  if (connected) await db.query('rollback').catch(() => {});
  await db.end();
}
