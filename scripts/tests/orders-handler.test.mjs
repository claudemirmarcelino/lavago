import test from 'node:test';
import assert from 'node:assert/strict';
import { createOrdersHandler } from '../../supabase/functions/_shared/orders-handler.js';
const id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const body={action:'create',machine_id:id,service_id:id,idempotency_key:id};
const request=(data=body, headers={})=>new Request('http://localhost/orders',{method:'POST',
 headers:{'content-type':'application/json',authorization:'Bearer test-session',origin:'http://localhost:3000',...headers},body:JSON.stringify(data)});
const handler=fetcher=>createOrdersHandler({url:'http://local',secret:'fixture-key',origins:['http://localhost:3000'],fetcher});
test('rejeita preço/dono/status fornecidos pelo cliente antes da chamada privilegiada',async()=>{
 for(const field of ['user_id','price_cents','status']) {
  const res=await handler(()=>{throw Error('não deve chamar')})(request({...body,[field]:id}));
  assert.equal(res.status,400);
 }
});
test('JWT validado no Auth determina o proprietário',async()=>{
 const calls=[];const res=await handler(async(url,options)=>{
  calls.push({url,options});return Response.json(calls.length===1?{id}:{id,status:'WAITING_PAYMENT'});
 })(request());
 assert.equal(res.status,200);assert.equal(calls.length,2);
 assert.equal(JSON.parse(calls[1].options.body).p_user_id,id);
 assert.equal(calls[0].options.headers.Authorization,'Bearer test-session');
});
test('token inválido nunca chega ao RPC',async()=>{
 let calls=0;const res=await handler(async()=>{calls++;return Response.json({}, {status:401});})(request());
 assert.equal(res.status,401);assert.equal(calls,1);
});
test('origem desconhecida bloqueada',async()=>{
 assert.equal((await handler(()=>{})(request(body,{origin:'https://untrusted.invalid'}))).status,403);
});
test('cancelamento usa dono validado; erro interno não vaza',async()=>{
 let calls=0; const res=await handler(async(url,options)=>{
  calls++;if(calls===1)return Response.json({id});
  assert.equal(JSON.parse(options.body).p_user_id,id);
  return Response.json({message:'sensitive database details'},{status:500});
 })(request({action:'cancel',order_id:id}));
 assert.deepEqual(await res.json(),{error:'ORDER_OPERATION_FAILED'});
});
test('conflito de reserva gera resposta tratável',async()=>{
 let calls=0;const res=await handler(async()=>++calls===1?Response.json({id}):Response.json({message:'MACHINE_RESERVED'},{status:400}))(request());
 assert.equal(res.status,409);assert.equal((await res.json()).error,'MACHINE_RESERVED');
});
