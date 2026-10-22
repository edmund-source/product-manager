// Folds a weekly delta sweep into the stored extracts, for the partner
// explorer's refresh. Companies match on website domain (unless it is a free
// mail domain), else on name. Lists are unioned; the newer record's status,
// summary and next step win; products and attachment files are added once.
//
//   node scripts/merge-incremental.mjs suppliers <base.json> <delta.json> <out.json>
//   node scripts/merge-incremental.mjs files     <base.json> <delta.json> <out.json>
//   node scripts/merge-incremental.mjs evidence  <base.json> <delta.json> <out.json>
import { readFile, writeFile } from 'node:fs/promises';

const [kind, baseFile, deltaFile, outFile] = process.argv.slice(2);
const read = async (f) => {
  try { return JSON.parse(await readFile(f, 'utf8')); } catch (e) { if (e.code === 'ENOENT') return []; throw e; }
};
const base = await read(baseFile);
const delta = await read(deltaFile);

const lower = (s) => (s ? String(s).toLowerCase().trim() : '');
const FREE_MAIL = ['gmail.com', 'yahoo.com', 'outlook.com', 'hotmail.com', 'qq.com', '163.com'];
const union = (a = [], b = [], key = (x) => JSON.stringify(x)) => {
  const seen = new Map();
  for (const x of [...a, ...b]) if (x != null) seen.set(key(x), x);
  return [...seen.values()];
};

let stats;
let out;
if (kind === 'suppliers') {
  const companyKey = (c) => {
    const d = lower(c.website_domain).replace(/^www\./, '');
    return d && !FREE_MAIL.includes(d) ? `d:${d}` : `n:${lower(c.company)}`;
  };
  const byKey = new Map(base.map((c) => [companyKey(c), c]));
  const byName = new Map(base.map((c) => [lower(c.company), c]));
  stats = { base: base.length, delta: delta.length, updated: 0, added: 0 };
  for (const d of delta) {
    const c = byKey.get(companyKey(d)) ?? byName.get(lower(d.company));
    if (!c) {
      base.push(d);
      byKey.set(companyKey(d), d);
      stats.added++;
      continue;
    }
    stats.updated++;
    const newer = (d.last_contact ?? '') >= (c.last_contact ?? '');
    for (const f of ['thread_ids', 'has_attachments', 'brands', 'partner_types']) c[f] = union(c[f], d[f], (x) => x);
    c.attachment_messages = union(c.attachment_messages, d.attachment_messages, (m) => `${m.message_id}|${m.filename}`);
    c.contacts = union(c.contacts, d.contacts, (p) => lower(p.email) || `name:${lower(p.name)}`);
    c.products = union(c.products, d.products,
      (p) => [lower(p.name), lower(p.model), p.price, p.quoted_on, lower(p.source)].join('|'));
    for (const f of ['website_domain', 'country', 'ph_presence', 'introduced_by']) c[f] = c[f] ?? d[f] ?? null;
    if ((d.first_contact ?? '9999') < (c.first_contact ?? '9999')) c.first_contact = d.first_contact;
    if (newer) {
      for (const f of ['status', 'summary', 'next_step', 'last_contact', 'kind', 'solar_related']) {
        if (d[f] != null) c[f] = d[f];
      }
    }
  }
  out = base;
} else if (kind === 'files') {
  // one object per attachment / price-list file; a re-read file replaces the old one
  const key = (f) => `${f.message_id ?? f.company}|${f.filename}`;
  out = union(base, delta, key);
  stats = { base: base.length, delta: delta.length, total: out.length };
} else if (kind === 'evidence') {
  out = union(base, delta, (e) => e.company);
  stats = { base: base.length, delta: delta.length, total: out.length };
} else {
  console.error('first argument must be suppliers, files or evidence');
  process.exit(2);
}
await writeFile(outFile, JSON.stringify(out, null, 1));
console.log({ kind, ...stats, out: outFile });
