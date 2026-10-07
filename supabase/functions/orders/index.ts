import { createOrdersHandler } from '../_shared/orders-handler.js';

const origins = (Deno.env.get('LAVAGO_ALLOWED_ORIGINS') ?? 'http://localhost:3000,http://127.0.0.1:3000')
  .split(',').map(value=>value.trim()).filter(Boolean);
const secrets = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
Deno.serve(createOrdersHandler({
  url:Deno.env.get('SUPABASE_URL'),
  secret:Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? secrets.default,
  origins,
}));
