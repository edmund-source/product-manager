// Database side of the weekly supplier inbox scanner, for local or direct
// Postgres use. The work is done by the scanner_* functions
// (supabase/migrations/20261024020000_scanner_functions.sql); cloud routines
// call the same functions through the Supabase connector instead, since cloud
// sessions cannot open direct database connections. Needs DATABASE_URL.
//
//   node scripts/scanner/db.mjs companies
//   node scripts/scanner/db.mjs run-start <classify|extract>
//   node scripts/scanner/db.mjs run-finish <run_id> <summary.json>
//   node scripts/scanner/db.mjs last <classify|extract>
//   node scripts/scanner/db.mjs classify <classified.json>
//   node scripts/scanner/db.mjs extract <extracted.json>
//   node scripts/scanner/db.mjs trade-credit <trade_credit.json>
import { readFile } from 'node:fs/promises';
import pg from 'pg';

const [cmd, arg1, arg2] = process.argv.slice(2);
if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is not set'); process.exit(2); }
const url = new URL(process.env.DATABASE_URL);
url.searchParams.delete('sslmode');
const client = new pg.Client({
  connectionString: url.toString(),
  ssl: /localhost|127\.0\.0\.1/.test(url.hostname) ? false : { rejectUnauthorized: false },
});
await client.connect();
const readJson = async (f) => JSON.parse(await readFile(f, 'utf8'));
const call = async (fn, ...params) =>
  (await client.query(`select ${fn}(${params.map((_, i) => '$' + (i + 1)).join(', ')}) as r`, params)).rows[0].r;

let out;
try {
  if (cmd === 'companies') out = { companies: await call('scanner_companies') };
  else if (cmd === 'run-start') out = await call('scanner_run_start', arg1);
  else if (cmd === 'run-finish') out = await call('scanner_run_finish', arg1, arg2 ? await readJson(arg2) : {});
  else if (cmd === 'last') out = await call('scanner_last', arg1);
  else if (cmd === 'classify') out = await call('scanner_classify', JSON.stringify(await readJson(arg1)));
  else if (cmd === 'extract') out = await call('scanner_extract', JSON.stringify(await readJson(arg1)));
  else if (cmd === 'trade-credit') out = await call('scanner_trade_credit', JSON.stringify(await readJson(arg1)));
  else throw new Error('command must be companies, run-start, run-finish, last, classify, extract or trade-credit');
  console.log(JSON.stringify(out, null, 1));
} catch (e) {
  console.error(e.message);
  process.exitCode = 1;
} finally {
  await client.end();
}
