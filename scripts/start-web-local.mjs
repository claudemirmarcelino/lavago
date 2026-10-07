import { execFileSync,spawn } from 'node:child_process';
import { writeFileSync,existsSync } from 'node:fs';
import { localDatabaseUrl } from './lib/local-database.mjs';
const cli='node_modules/supabase/dist/supabase.js';
let status;
try { status=JSON.parse(execFileSync(process.execPath,[cli,'status','-o','json'],{
 encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:25000})); }
catch { console.error('Supabase não respondeu. Abra o Docker e execute npm.cmd run dev:start antes de tentar novamente.');process.exit(1); }
const publicKey=status.PUBLISHABLE_KEY??status.ANON_KEY;
if(!publicKey||String(publicKey).startsWith('sb_secret_')){console.error('Chave pública local indisponível.');process.exit(1);}
process.env.LAVAGO_TEST_DATABASE_URL=status.DB_URL;
try{localDatabaseUrl();}catch{console.error('O iniciador só aceita o banco local na porta 54322.');process.exit(1);}
if(!existsSync('apps/web/node_modules/vite/bin/vite.js')){
 console.error('Instale a interface: cd apps/web e execute npm.cmd ci. Depois volte à raiz.');process.exit(1);
}
writeFileSync('apps/web/.env.local',`VITE_SUPABASE_URL=http://127.0.0.1:54321\nVITE_SUPABASE_PUBLISHABLE_KEY=${publicKey}\n`);
const children=[];let stopping=false;
function stop(code=0){if(stopping)return;stopping=true;for(const child of children)child.kill();process.exitCode=code;}
for(const args of [[cli,'functions','serve','orders'],['scripts/dev-catalog.mjs'],
 ['apps/web/node_modules/vite/bin/vite.js','apps/web','--host','127.0.0.1','--port','3000','--strictPort']]){
 const child=spawn(process.execPath,args,{stdio:'inherit',env:process.env,windowsHide:true});children.push(child);
 child.on('error',()=>{console.error('Não foi possível iniciar um dos serviços locais.');stop(1);});
 child.on('exit',code=>{if(!stopping)stop(code??1);});
}
process.on('SIGINT',()=>stop());process.on('SIGTERM',()=>stop());
console.log('LavaGo: http://127.0.0.1:3000 · mantenha este terminal aberto.');
console.log('Pedidos usam o backend real local. Pagamentos e equipamentos reais permanecem desligados.');
