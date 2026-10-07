import { Client } from 'pg';
import { localDatabaseUrl } from './lib/local-database.mjs';
const db=new Client({connectionString:localDatabaseUrl(),connectionTimeoutMillis:5000});
const machines=[1,2,3,4].map(i=>`90000000-0000-0000-0000-00000000000${i}`);
const services=['91000000-0000-0000-0000-000000000001','91000000-0000-0000-0000-000000000002'];
let timer;
try{
 await db.connect();await db.query('begin');
 for(const [i,id] of machines.entries())await db.query(`insert into public.machines(id,code,label,operational_status,last_seen_at)
 values($1,$2,$3,$4,clock_timestamp()) on conflict(id) do nothing`,[id,`DEMO-WEB-0${i+1}`,`Lavadora ${String(i+1).padStart(2,'0')}`,i===3?'MAINTENANCE':'ACTIVE']);
 for(const [i,id] of services.entries())await db.query(`insert into public.services(id,name,price_cents,active)
 values($1,$2,$3,true) on conflict(id) do nothing`,[id,i?'Lavagem delicada':'Lavagem completa',i?3500:2500]);
 for(const machine of machines)for(const service of services)await db.query('insert into public.machine_services values($1,$2) on conflict do nothing',[machine,service]);
 await db.query('commit');
 const heartbeat=()=>db.query('update public.machines set last_seen_at=clock_timestamp() where id=any($1::uuid[])',[machines]);
 await heartbeat();timer=setInterval(()=>heartbeat().catch(()=>console.error('Heartbeat de demonstração indisponível.')),30000);
 console.log('Catálogo local de demonstração pronto. Nenhuma máquina física conectada.');
}catch(error){await db.query('rollback').catch(()=>{});console.error('Falha ao preparar catálogo local:',error.code??'conexão indisponível');await db.end();process.exitCode=1;}
async function stop(){clearInterval(timer);await db.end().catch(()=>{});process.exit();}
process.on('SIGINT',stop);process.on('SIGTERM',stop);
