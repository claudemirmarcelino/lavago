import { readdir, readFile } from 'node:fs/promises';
import { Client } from 'pg';
import { localDatabaseUrl } from './lib/local-database.mjs';

const db = new Client({ connectionString: localDatabaseUrl(), connectionTimeoutMillis: 5000, statement_timeout: 30000 });
let connected = false;
let total = 0;
try {
  await db.connect(); connected = true;
  for (const file of (await readdir('supabase/tests/database')).filter(f => f.endsWith('.test.sql')).sort()) {
    const result = await db.query(await readFile(`supabase/tests/database/${file}`, 'utf8'));
    const lines = (Array.isArray(result) ? result : [result]).flatMap(r => r.rows.flatMap(Object.values))
      .filter(v => typeof v === 'string').flatMap(v => v.split('\n'));
    const assertions = lines.filter(l => /^(?:not )?ok \d+/.test(l));
    const plans = lines.filter(l => /^1\.\.\d+$/.test(l));
    const failures = lines.filter(l => /^(not ok|Bail out!|# Looks like)/.test(l));
    if (plans.length !== 1 || Number(plans[0].slice(3)) !== assertions.length || failures.length) {
      throw new Error(`${file}: plano/assertivas inconsistentes ou testes falharam\n${failures.join('\n')}`);
    }
    total += assertions.length;
    console.log(`PASS: ${file} (${assertions.length})`);
  }
  if (!total) throw new Error('Nenhum teste executado');
  console.log(`PASS: ${total} verificações SQL`);
} catch (error) { console.error(error.message); process.exitCode = 1; }
finally {
  if (connected) await db.query('rollback').catch(() => {});
  await db.end();
}
