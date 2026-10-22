// Applies supabase/migrations/*.sql in filename order, once each.
import { readdir, readFile } from 'node:fs/promises';
import pg from 'pg';

const dir = new URL('../supabase/migrations/', import.meta.url);
const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();

await client.query(`create table if not exists schema_migrations (
  version text primary key, applied_at timestamptz not null default now())`);
const { rows } = await client.query('select version from schema_migrations');
const applied = new Set(rows.map((r) => r.version));

for (const file of (await readdir(dir)).filter((f) => f.endsWith('.sql')).sort()) {
  if (applied.has(file)) continue;
  const sql = await readFile(new URL(file, dir), 'utf8');
  await client.query('begin');
  try {
    await client.query(sql);
    await client.query('insert into schema_migrations (version) values ($1)', [file]);
    await client.query('commit');
    console.log(`applied ${file}`);
  } catch (err) {
    await client.query('rollback');
    console.error(`failed ${file}: ${err.message}`);
    process.exitCode = 1;
    break;
  }
}
await client.end();
