import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

export function localDatabaseUrl() {
  let value = process.env.LAVAGO_TEST_DATABASE_URL;
  if (!value) {
    try {
      value = JSON.parse(execFileSync(process.execPath,
        ['node_modules/supabase/dist/supabase.js', 'status', '-o', 'json'],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 15000 })).DB_URL;
    } catch { throw new Error('Inicie a stack local ou configure LAVAGO_TEST_DATABASE_URL na sessão.'); }
  }
  let url;
  try { url = new URL(value); } catch { throw new Error('URL local ausente ou inválida'); }
  assert(['postgres:', 'postgresql:'].includes(url.protocol), 'Protocolo inválido');
  assert(['localhost', '127.0.0.1', '[::1]'].includes(url.hostname), 'Somente banco local');
  assert.equal(url.port, '54322', 'Somente porta local 54322');
  return value;
}
