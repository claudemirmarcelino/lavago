const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const conflicts = new Set(['MACHINE_RESERVED','MACHINE_OFFLINE','MACHINE_UNAVAILABLE','SERVICE_UNAVAILABLE',
  'SERVICE_INCOMPATIBLE','ORDER_REQUIRES_RECONCILIATION','IDEMPOTENCY_CONFLICT']);

export function createOrdersHandler({ url, secret, origins, fetcher = fetch }) {
  return async request => {
    const origin = request.headers.get('origin');
    const headers = { 'Content-Type':'application/json', 'Cache-Control':'no-store', 'Vary':'Origin' };
    if (origin && origins.includes(origin)) headers['Access-Control-Allow-Origin'] = origin;
    const reply = (status, data) => new Response(JSON.stringify(data), { status, headers });
    if (origin && !origins.includes(origin)) return reply(403, { error:'ORIGIN_NOT_ALLOWED' });
    if (request.method === 'OPTIONS') return new Response(null, { status:204, headers:{ ...headers,
      'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info',
      'Access-Control-Allow-Methods':'POST, OPTIONS' } });
    if (request.method !== 'POST') return reply(405, { error:'METHOD_NOT_ALLOWED' });
    if (!url || !secret) return reply(503, { error:'BACKEND_NOT_CONFIGURED' });
    const authorization = request.headers.get('authorization') ?? '';
    if (!/^Bearer \S+$/i.test(authorization)) return reply(401, { error:'AUTH_REQUIRED' });
    if (!(request.headers.get('content-type') ?? '').startsWith('application/json')) return reply(415, { error:'JSON_REQUIRED' });
    try {
      const raw = await request.text();
      if (raw.length > 4096) return reply(413, { error:'REQUEST_TOO_LARGE' });
      let body;
      try { body = JSON.parse(raw); } catch { return reply(400, { error:'INVALID_REQUEST' }); }
      if (!body || Array.isArray(body) || typeof body !== 'object') return reply(400, { error:'INVALID_REQUEST' });
      const fields = body.action === 'create' ? ['action','machine_id','service_id','idempotency_key']
        : body.action === 'cancel' ? ['action','order_id'] : [];
      if (!fields.length || Object.keys(body).some(k=>!fields.includes(k)) ||
        fields.filter(k=>k!=='action').some(k=>typeof body[k]!=='string' || !uuid.test(body[k]))) {
        return reply(400, { error:'INVALID_REQUEST' });
      }
      // Validação remota do JWT; não confiar em claims decodificados pelo cliente.
      const auth = await fetcher(`${url}/auth/v1/user`, { headers:{ apikey:secret, Authorization:authorization },
        signal:AbortSignal.timeout(10000) });
      if (!auth.ok) return reply(auth.status >= 500 ? 503 : 401, { error:auth.status >= 500 ? 'AUTH_UNAVAILABLE' : 'AUTH_REQUIRED' });
      const user = await auth.json();
      if (!uuid.test(user.id ?? '')) return reply(401, { error:'AUTH_REQUIRED' });
      const args = body.action === 'create'
        ? { p_user_id:user.id,p_machine_id:body.machine_id,p_service_id:body.service_id,p_idempotency_key:body.idempotency_key }
        : { p_user_id:user.id,p_order_id:body.order_id };
      const result = await fetcher(`${url}/rest/v1/rpc/${body.action === 'create' ? 'create_order' : 'cancel_order'}`, {
        method:'POST', headers:{ apikey:secret,Authorization:`Bearer ${secret}`,'Content-Type':'application/json' },
        body:JSON.stringify(args),signal:AbortSignal.timeout(15000) });
      const data = await result.json();
      if (!result.ok) {
        if (conflicts.has(data.message)) return reply(409, { error:data.message });
        if (data.message === 'ORDER_NOT_FOUND' || data.message === 'MACHINE_NOT_FOUND') return reply(404, { error:data.message });
        return reply(500, { error:'ORDER_OPERATION_FAILED' });
      }
      return reply(200, { order:Array.isArray(data) ? data[0] : data });
    } catch { return reply(503, { error:'BACKEND_UNAVAILABLE' }); }
  };
}
