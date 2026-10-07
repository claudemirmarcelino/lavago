import { createClient } from '@supabase/supabase-js';
import './style.css';

const root=document.querySelector('#app');
const url=import.meta.env.VITE_SUPABASE_URL;
const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
function publicKey(value){
 if(!value)return false;
 if(value.startsWith('sb_publishable_'))return true;
 try{return JSON.parse(atob(value.split('.')[1].replace(/-/g,'+').replace(/_/g,'/'))).role==='anon';}catch{return false;}
}
const configured=Boolean(url && publicKey(key));
const api=configured?createClient(url,key):null;
const state={session:null,tab:'machines',machines:[],services:[],links:[],orders:[],cycles:[],payments:[],
 loading:false,busy:false,preview:false,selected:null,service:null,notice:'',error:'',authMode:'login',authOpen:false,request:null};
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=n=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format(n/100);
const date=s=>new Intl.DateTimeFormat('pt-BR',{dateStyle:'short',timeStyle:'short'}).format(new Date(s));
const labels={WAITING_PAYMENT:'Aguardando pagamento',AUTHORIZED:'Autorizado',IN_PROGRESS:'Em andamento',COMPLETED:'Concluído',
 CANCELLED:'Cancelado',EXPIRED:'Expirado',NEEDS_REVIEW:'Precisa de atendimento',PENDING_START:'Aguardando início',RUNNING:'Lavando',
 FINISHED:'Finalizado',UNKNOWN:'Aguardando verificação',FAILED:'Falha',PENDING:'Pendente',APPROVED:'Confirmado',REFUNDED:'Estornado'};
const errors={MACHINE_RESERVED:'Esta máquina acabou de ser reservada. Escolha outra.',MACHINE_OFFLINE:'A máquina está sem comunicação. Escolha outra.',
 MACHINE_UNAVAILABLE:'Esta máquina não está disponível agora.',SERVICE_UNAVAILABLE:'Este serviço não está disponível.',
 SERVICE_INCOMPATIBLE:'Este serviço não pode ser usado nesta máquina.',ORDER_REQUIRES_RECONCILIATION:'Este pedido precisa de atendimento antes de ser cancelado.',
 AUTH_REQUIRED:'Sua sessão expirou. Entre novamente.',BACKEND_UNAVAILABLE:'Não foi possível alcançar o servidor. Tente novamente.',
 IDEMPOTENCY_CONFLICT:'A solicitação mudou. Feche a seleção e tente novamente.'};
const icon=(name)=>({wash:'◉',clock:'◷',orders:'▤',arrow:'↗',check:'✓',close:'×',refresh:'↻'}[name]??name);
function machineState(m){
 if(m.operational_status==='MAINTENANCE')return ['Manutenção','maintenance'];
 if(!state.preview&&(!m.last_seen_at||Date.now()-new Date(m.last_seen_at).getTime()>120000))return ['Sem conexão','offline'];
 if(state.orders.some(o=>o.machine_id===m.id&&['WAITING_PAYMENT','AUTHORIZED','IN_PROGRESS','NEEDS_REVIEW'].includes(o.status)))return ['Seu pedido ativo','occupied'];
 return ['Consultar reserva','available'];
}
const demoMachines=[1,2,3,4].map((i)=>({id:`demo-${i}`,code:`L0${i}`,label:`Lavadora ${String(i).padStart(2,'0')}`,
 operational_status:i===4?'MAINTENANCE':'ACTIVE',last_seen_at:new Date().toISOString()}));
function render(){
 const visible=state.preview?demoMachines:state.machines;
 const count=visible.filter(m=>machineState(m)[1]==='available').length;
 root.innerHTML=`<div class="layout"><aside class="sidebar">
 <a class="brand" href="#" aria-label="LavaGo início"><span class="brand-icon">↻</span>Lava<span>Go</span><i>●</i></a>
 <div class="workspace"><span class="tiny">SUA LAVANDERIA</span><strong>LavaGo Self-service</strong><span>Seu tempo de volta.</span></div>
 <nav aria-label="Menu principal"><button data-tab="machines" class="nav-item ${state.tab==='machines'?'active':''}"><span>◉</span> Máquinas <b>↗</b></button>
 <button data-tab="orders" class="nav-item ${state.tab==='orders'?'active':''}"><span>▤</span> Meus pedidos ${state.orders.length?`<small>${state.orders.length}</small>`:''}</button>
 <button data-tab="guide" class="nav-item ${state.tab==='guide'?'active':''}"><span>ⓘ</span> Como funciona</button></nav>
 <div class="sidebar-bottom"><div class="help-icon">✳</div><strong>Um cuidado a menos<br>no seu dia.</strong><p>Escolha a máquina.<br>Acompanhe tudo por aqui.</p></div>
 <div class="environment"><span></span> Ambiente local de desenvolvimento</div></aside>
 <div class="main-shell"><header><div class="breadcrumb">Lavanderia <span>/</span> <strong>${state.tab==='machines'?'Máquinas':state.tab==='orders'?'Meus pedidos':'Como funciona'}</strong></div>
 <div class="header-actions"><span class="local-tag">${state.preview?'Demonstração':'LavaGo · local'}</span>${state.session?`<button id="logout" class="text-button">Sair</button><span class="avatar">${escape(state.session.user.email?.slice(0,1).toUpperCase())}</span>`:'<button id="login" class="button small">Entrar <span>↗</span></button>'}</div></header>
 <main>${state.error?`<div role="alert" class="notice error">${escape(state.error)} <button id="dismiss" aria-label="Fechar aviso">×</button></div>`:''}
 ${state.notice?`<div role="status" class="notice">${escape(state.notice)}</div>`:''}
 ${state.preview?'<div class="preview-bar">Demonstração visual · máquinas fictícias · nenhuma cobrança <button id="exit-preview">Sair da demonstração</button></div>':''}
 ${state.tab==='machines'?`<section class="hero"><div class="hero-copy"><div class="eyebrow"><span></span> MENOS ROTINA. MAIS TEMPO PRA VOCÊ.</div><h1>Roupa limpa.<br><em>Dia mais leve.</em></h1><p>Sua próxima lavagem começa aqui.<br>Escolha uma máquina e deixe o resto fluir.</p>
 <div class="hero-note"><span>✓</span> Escolha, reserve e acompanhe em um só lugar.</div></div><div class="hero-art" aria-hidden="true"><div class="orbit one"></div><div class="orbit two"></div><span class="spark s1">✳</span><span class="spark s2">✧</span><div class="washer"><div class="washer-top"><span></span><i></i><i></i></div><div class="washer-door"><div class="cloth c1"></div><div class="cloth c2"></div><div class="glass-shine"></div></div><div class="washer-base"></div></div><div class="float-note">✦ &nbsp; Mais tempo para o que importa</div></div></section>
 <section class="catalog"><div class="section-heading"><div><div class="eyebrow muted">ESCOLHA SEU PRÓXIMO CICLO</div><h2>Encontre sua máquina<span>.</span></h2></div><button id="refresh" class="refresh" ${state.loading?'disabled':''}>↻ <span>${state.loading?'Atualizando…':'Atualizar'}</span></button></div>
 <div class="catalog-meta"><span class="chip selected">Todas as máquinas <b>${visible.length}</b></span><span class="status-summary"><i></i>${count} com conexão recente</span></div>
 ${state.loading&&!visible.length?'<div class="empty">Carregando máquinas…</div>':visible.length?`<div class="machine-grid">${visible.map(machineCard).join('')}</div><p class="fine-print">A disponibilidade da reserva é confirmada pelo servidor ao continuar. A conexão recente não garante uma máquina livre.</p>`:
 `<div class="empty"><span class="empty-icon">◉</span><h3>${state.session?'Nenhuma máquina cadastrada ainda':'Sua lavanderia, ao seu alcance'}</h3><p>${state.session?'O catálogo local está vazio. Cadastre os equipamentos de teste para começar.':'Entre para consultar o catálogo real e acompanhar seus pedidos.'}</p><div><button id="empty-login" class="button">${state.session?'Atualizar catálogo':'Entrar na minha conta'} <span>↗</span></button>${!state.session?'<button id="preview" class="button secondary">Explorar demonstração</button>':''}</div></div>`}</section>
 <section class="steps-strip"><div><span>01</span><p><strong>Escolha</strong>Uma máquina e seu serviço.</p></div><div><span>02</span><p><strong>Reserve</strong>Confira os detalhes do pedido.</p></div><div><span>03</span><p><strong>Acompanhe</strong>Veja o progresso do seu ciclo.</p></div></section>`:
 state.tab==='orders'?ordersView():guideView()}
 <footer><span class="footer-brand">LavaGo<span>●</span></span><span>Cuidado com suas roupas. Respeito pelo seu tempo.</span><small>Primeira versão · ambiente local</small></footer></main></div></div>
 ${state.authOpen?authDialog():''}${state.selected?selectionDialog():''}`;
 bind();
}
function machineCard(m){const [label,status]=machineState(m);return `<article class="machine-card"><div class="card-top"><span class="machine-code">${escape(m.code)}</span><span class="status ${status}"><i></i>${label}</span></div>
 <div class="mini-washer ${status}" aria-hidden="true"><div class="mini-controls">— <i>●</i></div><div class="mini-door">≈</div></div><div class="machine-info"><span class="tiny">LAVAGEM</span><h3>${escape(m.label)}</h3><p>${status==='maintenance'?'Estamos cuidando desta máquina.':status==='offline'?'Aguardando conexão com o equipamento.':'Escolha um serviço para ver os detalhes.'}</p></div>
 <button data-machine="${escape(m.id)}" class="card-button" ${status!=='available'?'disabled':''}>${status==='maintenance'?'Em manutenção':status==='offline'?'Indisponível':status==='occupied'?'Pedido em andamento':'Escolher máquina'}<span>↗</span></button></article>`;}
function ordersView(){return `<section class="page-title"><span class="eyebrow muted">TUDO NO SEU TEMPO</span><h1>Meus pedidos<span>.</span></h1><p>Acompanhe sua reserva e cada etapa da lavagem.</p></section><div class="section-heading"><h2>Seu histórico</h2><button class="refresh" id="refresh">↻ Atualizar</button></div>
 ${!state.session?'<div class="empty"><h3>Seus pedidos ficam aqui</h3><p>Entre na sua conta para acompanhar suas lavagens.</p><button class="button" id="empty-login">Entrar</button></div>':!state.orders.length?'<div class="empty"><h3>Pronto para a primeira lavagem?</h3><p>Escolha uma máquina para criar seu primeiro pedido.</p><button class="button" data-tab="machines">Ver máquinas ↗</button></div>':`<div class="order-list">${state.orders.map(o=>{const c=state.cycles.find(c=>c.order_id===o.id);const p=state.payments.filter(p=>p.order_id===o.id);return `<article class="order-card"><div class="order-head"><div><span class="tiny">PEDIDO ${escape(o.id.slice(0,8).toUpperCase())}</span><h3>${escape(state.machines.find(m=>m.id===o.machine_id)?.label??'Máquina')}</h3><p>${date(o.created_at)}</p></div><span class="order-status">${labels[o.status]??escape(o.status)}</span></div><div class="order-detail"><span>${escape(state.services.find(s=>s.id===o.service_id)?.name??'Serviço de lavagem')}</span><strong>${money(o.price_cents)}</strong></div>
 <div class="progress-track"><span class="done">✓ Pedido criado</span><span class="${['AUTHORIZED','IN_PROGRESS','COMPLETED'].includes(o.status)?'done':''}">Pagamento</span><span class="${['RUNNING','FINISHED'].includes(c?.status)?'done':''}">Lavagem</span><span class="${o.status==='COMPLETED'?'done':''}">Finalização</span></div>
 ${c?`<p class="order-note">Ciclo: ${labels[c.status]??escape(c.status)}</p>`:''}${p.length?`<p class="order-note">Pagamento: ${labels[p[0].status]??escape(p[0].status)}</p>`:''}
 ${o.status==='WAITING_PAYMENT'?`<div class="order-bottom"><p>Reserva até ${date(o.expires_at)}.<br>Pagamento real ainda não disponível nesta versão.</p><button class="text-button danger" data-cancel="${o.id}" ${state.busy?'disabled':''}>Cancelar pedido</button></div>`:''}
 ${o.status==='NEEDS_REVIEW'?'<p class="notice">Este pedido precisa de verificação. A máquina permanece reservada por segurança.</p>':''}</article>`;}).join('')}</div>`}`;}
function guideView(){return `<section class="page-title"><span class="eyebrow muted">SIMPLES DO COMEÇO AO FIM</span><h1>Como funciona<span>.</span></h1><p>Uma rotina mais leve começa com alguns passos.</p></section><div class="guide-grid">${[['01','Escolha sua máquina','Entre na sua conta, veja as máquinas e selecione o serviço desejado.'],['02','Confirme sua reserva','O servidor verifica a disponibilidade e define o preço e o prazo da reserva.'],['03','Acompanhe o pedido','Consulte o pagamento e o ciclo na área Meus pedidos.'],['04','Retire suas roupas','A finalização confirmada libera a máquina para a próxima lavagem.']].map(([n,t,d])=>`<article><span>${n}</span><h2>${t}</h2><p>${d}</p></article>`).join('')}</div><div class="notice">Esta versão é para desenvolvimento: ainda não recebe pagamentos reais nem aciona lavadoras.</div>`;}
function authDialog(){return `<div class="modal-backdrop"><section class="modal" role="dialog" aria-modal="true" aria-labelledby="auth-title"><button class="close" id="close-auth" aria-label="Fechar">×</button><span class="eyebrow muted">BEM-VINDO AO LAVAGO</span><h2 id="auth-title">${state.authMode==='login'?'Seu próximo ciclo<br>começa aqui.':'Mais tempo para você.'}</h2><p>${state.authMode==='login'?'Entre para reservar uma máquina.':'Crie sua conta para começar.'}</p>
 <form id="auth-form"><label>E-mail<input name="email" type="email" required autocomplete="email" placeholder="voce@exemplo.com"></label><label>Senha<input name="password" type="password" required minlength="12" autocomplete="${state.authMode==='login'?'current-password':'new-password'}" placeholder="Mínimo de 12 caracteres"></label><p id="auth-feedback" role="status"></p><button class="button full" ${state.busy?'disabled':''}>${state.busy?'Aguarde…':state.authMode==='login'?'Entrar na minha conta':'Criar minha conta'} ↗</button></form>
 <button class="text-button full" id="toggle-auth">${state.authMode==='login'?'Ainda não tem conta? Cadastre-se':'Já tem conta? Entrar'}</button>${!configured?'<div class="notice">A conexão local ainda não foi configurada. A demonstração visual está disponível na página inicial.</div>':''}</section></div>`;}
function selectionDialog(){const m=state.selected;const options=state.preview?[{id:'demo-service',name:'Lavagem completa',price_cents:2500}]:state.services.filter(s=>state.links.some(l=>l.machine_id===m.id&&l.service_id===s.id));
 const selected=options.find(s=>s.id===state.service);return `<div class="modal-backdrop"><section class="modal" role="dialog" aria-modal="true" aria-labelledby="selection-title"><button class="close" id="close-selection" aria-label="Fechar" ${state.busy?'disabled':''}>×</button><span class="eyebrow muted">UM PASSO PARA COMEÇAR</span><h2 id="selection-title">${escape(m.label)}</h2><p>Escolha o cuidado ideal para suas roupas.</p><div class="service-options">${options.map(s=>`<button class="service-option ${state.service===s.id?'chosen':''}" data-service="${s.id}"><span><strong>${escape(s.name)}</strong><small>Preço confirmado pelo servidor</small></span><b>${money(s.price_cents)}</b></button>`).join('')||'<p>Nenhum serviço ativo para esta máquina.</p>'}</div>
 <div class="reservation-summary"><span>Valor do catálogo</span><strong>${selected?money(selected.price_cents):'—'}</strong></div><p class="fine-print">A reserva vale por 10 minutos. A confirmação depende da disponibilidade no momento do pedido.</p><p id="selection-feedback" role="status"></p><button id="reserve" class="button full" ${!selected||state.busy?'disabled':''}>${state.preview?'Entrar para reservar':state.busy?'Verificando disponibilidade…':'Confirmar reserva'} ↗</button>${state.preview?'<p class="fine-print">Demonstração: dados e preço fictícios.</p>':''}</section></div>`;}
function bind(){
 document.querySelectorAll('[data-tab]').forEach(b=>b.onclick=()=>{state.tab=b.dataset.tab;state.error='';render();if(state.session)load();});
 document.querySelectorAll('[data-machine]').forEach(b=>b.onclick=()=>{state.selected=(state.preview?demoMachines:state.machines).find(m=>m.id===b.dataset.machine);state.service=null;state.request=null;render();});
 document.querySelectorAll('[data-service]').forEach(b=>b.onclick=()=>{state.service=b.dataset.service;state.request=null;render();});
 document.querySelectorAll('[data-cancel]').forEach(b=>b.onclick=()=>cancel(b.dataset.cancel));
 const on=(id,fn)=>{const el=document.getElementById(id);if(el)el.onclick=fn;};
 const openAuth=()=>{state.authOpen=true;render();document.querySelector('input[name=email]')?.focus();};
 on('login',openAuth);on('empty-login',()=>state.session?load():openAuth());
 on('logout',async()=>{await api.auth.signOut();state.orders=[];state.cycles=[];state.payments=[];state.machines=[];state.session=null;render();});
 on('close-auth',()=>{state.authOpen=false;render();});on('toggle-auth',()=>{state.authMode=state.authMode==='login'?'signup':'login';render();});
 on('preview',()=>{state.preview=true;render();});on('exit-preview',()=>{state.preview=false;render();});
 on('refresh',()=>state.preview?render():load());on('dismiss',()=>{state.error='';render();});
 on('close-selection',()=>{if(!state.busy){state.selected=null;render();}});on('reserve',reserve);
 const form=document.querySelector('#auth-form');if(form)form.onsubmit=authenticate;
}
async function authenticate(event){event.preventDefault();const feedback=document.querySelector('#auth-feedback');
 if(!api){feedback.textContent='Conexão ainda não configurada. Use a demonstração por enquanto.';return;}
 const data=new FormData(event.target);const button=event.target.querySelector('button');button.disabled=true;button.textContent='Aguarde…';
 try{const input={email:String(data.get('email')),password:String(data.get('password'))};
 const {error}=state.authMode==='login'?await api.auth.signInWithPassword(input):await api.auth.signUp({...input,options:{emailRedirectTo:window.location.origin}});
 if(error){feedback.textContent=error.message==='Invalid login credentials'?'E-mail ou senha incorretos.':error.message==='Email not confirmed'?'Confirme seu e-mail antes de entrar.':'Não foi possível entrar ou cadastrar. Confira os dados e a conexão.';}
 else if(state.authMode==='signup'){feedback.textContent='Confira seu e-mail para confirmar a conta. No ambiente local, use a caixa Mailpit.';}
 else{state.authOpen=false;state.preview=false;render();}
 }catch{feedback.textContent='Servidor indisponível. Tente novamente.';}finally{button.disabled=false;button.textContent=state.authMode==='login'?'Entrar na minha conta':'Criar minha conta';}}
let loadVersion=0;
async function load(){if(!api||!state.session||state.loading)return;state.loading=true;const version=++loadVersion;render();
 try{const results=await Promise.all([api.from('machines').select('*').order('code'),api.from('services').select('*').order('name'),api.from('machine_services').select('*'),api.from('orders').select('*').order('created_at',{ascending:false}).limit(30),api.from('washing_cycles').select('*'),api.from('payments').select('*').order('created_at',{ascending:false})]);
 if(results.some(r=>r.error))throw Error('load');if(version!==loadVersion||!state.session)return;
 [state.machines,state.services,state.links,state.orders,state.cycles,state.payments]=results.map(r=>r.data);state.error='';
 }catch{state.error='Não foi possível atualizar os dados. Verifique se o ambiente local está iniciado.';}finally{state.loading=false;render();}}
async function mutate(body){const {data:{session}}=await api.auth.getSession();if(!session)throw Error('AUTH_REQUIRED');
 const res=await fetch(`${url}/functions/v1/orders`,{method:'POST',headers:{'Content-Type':'application/json',apikey:key,Authorization:`Bearer ${session.access_token}`},body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});
 const result=await res.json();if(!res.ok)throw Error(result.error??'BACKEND_UNAVAILABLE');return result.order;}
async function reserve(){if(state.preview){state.selected=null;state.authOpen=true;render();return;}if(state.busy||!state.service)return;
 if(!state.request)state.request={action:'create',machine_id:state.selected.id,service_id:state.service,idempotency_key:crypto.randomUUID()};
 state.busy=true;render();try{await mutate(state.request);state.selected=null;state.request=null;state.tab='orders';state.notice='Reserva criada. Acompanhe os detalhes do pedido abaixo.';state.busy=false;await load();}
 catch(error){state.busy=false;render();document.querySelector('#selection-feedback').textContent=errors[error.message]??'Não foi possível confirmar. Tente novamente; a mesma solicitação será reutilizada.';}}
async function cancel(id){if(state.busy||!window.confirm('Cancelar este pedido e liberar sua reserva?'))return;state.busy=true;render();
 try{const order=await mutate({action:'cancel',order_id:id});state.notice=['CANCELLED','EXPIRED'].includes(order.status)?'Reserva liberada.':'O pedido já mudou de estado e não foi cancelado.';state.busy=false;await load();}
 catch(error){state.busy=false;state.error=errors[error.message]??'Não foi possível cancelar o pedido.';render();}}
document.addEventListener('keydown',e=>{
 if(e.key==='Escape'&&!state.busy){state.authOpen=false;state.selected=null;render();}
 if(e.key==='Tab'){
  const modal=document.querySelector('.modal');if(!modal)return;
  const items=[...modal.querySelectorAll('button:not([disabled]),input,a[href]')];
  if(!items.length)return;
  if(e.shiftKey&&(document.activeElement===items[0]||!modal.contains(document.activeElement))){e.preventDefault();items.at(-1).focus();}
  else if(!e.shiftKey&&(document.activeElement===items.at(-1)||!modal.contains(document.activeElement))){e.preventDefault();items[0].focus();}
 }
});
render();
if(api){api.auth.getSession().then(({data})=>{state.session=data.session;render();if(state.session)load();});
 api.auth.onAuthStateChange((_event,session)=>{state.session=session;if(!session){loadVersion++;state.orders=[];state.cycles=[];state.payments=[];state.machines=[];}setTimeout(()=>{render();if(session)load();},0);});}
setInterval(()=>{if(!document.hidden&&state.session&&!state.selected&&!state.authOpen&&!state.busy)load();},15000);
