// Loads the supplier list extracted from Gmail (see data/suppliers_from_gmail.json)
// into the register. Safe to re-run: companies, brands and contacts are
// upserted; offers, interactions and documents that came from email are
// replaced per company on each run.
//
//   DATABASE_URL=... node scripts/import-gmail-suppliers.mjs data/suppliers_from_gmail.json
import { readFile } from 'node:fs/promises';
import pg from 'pg';

const file = process.argv[2] ?? 'data/suppliers_from_gmail.json';
const companies = JSON.parse(await readFile(file, 'utf8'));

const KINDS = ['manufacturer', 'distributor', 'wholesaler', 'installer', 'service',
  'software', 'logistics', 'financing', 'bank', 'lender', 'investor', 'insurer', 'event', 'other'];
const STATUSES = ['cold_inbound', 'intro', 'in_discussion', 'quoted', 'meeting_held',
  'accredited', 'active_supplier', 'declined', 'dormant', 'unknown'];
const BASES = ['exw', 'fob', 'cif', 'ddp', 'delivered', 'retail', 'wholesale'];
const PARTNER_TYPE_ALIASES = {
  inverter: 'inverters', panel: 'panels', modules: 'panels', pv_modules: 'panels',
  battery: 'batteries', bess: 'batteries', energy_storage: 'batteries',
  racking: 'mounting', ats: 'bos', consumables: 'bos', ev_charger: 'ev_charging',
  ev_chargers: 'ev_charging', saas: 'software', event: 'events', service: 'services',
  financing: 'consumer_financing', finance: 'consumer_financing', loans: 'consumer_financing',
  debt: 'business_financing', lending: 'business_financing', equity: 'investment',
};

const oneOf = (v, allowed, fallback) => (allowed.includes(v) ? v : fallback);
const slug = (s) => String(s).toLowerCase().trim().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');
const docKind = (name) => {
  const n = name.toLowerCase();
  if (/price|quot/.test(n)) return 'price_list';
  if (/brochure|catalog/.test(n)) return 'brochure';
  if (/profile/.test(n)) return 'company_profile';
  if (/datasheet|spec/.test(n)) return 'datasheet';
  if (/cert|iec|ul\b/.test(n)) return 'certificate';
  if (/agreement|contract|moa|nda/.test(n)) return 'contract';
  return 'other';
};

const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
await client.connect();
const { rows: ptRows } = await client.query('select key from partner_types');
const partnerTypeKeys = new Set(ptRows.map((r) => r.key));
const toPartnerType = (t) => {
  const k = PARTNER_TYPE_ALIASES[slug(t)] ?? slug(t);
  return partnerTypeKeys.has(k) ? k : 'other';
};

let counts = { companies: 0, contacts: 0, offers: 0, documents: 0, interactions: 0 };
for (const c of companies) {
  await client.query('begin');
  try {
    const domain = c.website_domain?.toLowerCase().replace(/^www\./, '') || null;
    // Match on domain first, then name, so a renamed company isn't duplicated.
    const existing = await client.query(
      'select id from companies where website_domain = $1 or lower(name) = lower($2) limit 1',
      [domain, c.company],
    );
    const values = [
      c.company, domain, c.country ?? null, oneOf(c.kind, KINDS, 'other'),
      c.solar_related ?? true, oneOf(c.status, STATUSES, 'unknown'),
      c.kind === 'event' ? 3 : null, c.introduced_by ?? null, c.summary ?? null,
      c.first_contact ?? null, c.last_contact ?? null,
    ];
    let companyId;
    if (existing.rows.length) {
      companyId = existing.rows[0].id;
      await client.query(
        `update companies set name=$2, website_domain=coalesce($3, website_domain),
           country=coalesce($4, country), kind=$5, solar_related=$6, status=$7,
           priority=coalesce(priority, $8), introduced_by=coalesce($9, introduced_by),
           summary=$10, first_contact_on=$11, last_contact_on=$12
         where id=$1`,
        [companyId, ...values],
      );
    } else {
      const r = await client.query(
        `insert into companies (name, website_domain, country, kind, solar_related, status,
           priority, introduced_by, summary, first_contact_on, last_contact_on)
         values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) returning id`,
        values,
      );
      companyId = r.rows[0].id;
    }
    counts.companies++;

    // partner_types is the tagging; older extracts only had categories.
    const types = c.partner_types?.length ? c.partner_types : (c.categories ?? []);
    for (const t of new Set(types.map(toPartnerType))) {
      await client.query(
        'insert into company_partner_types values ($1,$2) on conflict do nothing',
        [companyId, t],
      );
    }

    for (const brand of c.brands ?? []) {
      const b = await client.query(
        `insert into brands (name) values ($1)
         on conflict (name) do update set name = brands.name returning id`,
        [brand],
      );
      const rel = c.kind === 'manufacturer' ? 'manufacturer' : 'unknown';
      await client.query(
        `insert into company_brands values ($1,$2,$3) on conflict do nothing`,
        [companyId, b.rows[0].id, rel],
      );
    }

    if (c.ph_presence) {
      const has = await client.query(
        'select 1 from company_locations where company_id=$1 and address=$2',
        [companyId, c.ph_presence],
      );
      if (!has.rows.length) {
        await client.query(
          `insert into company_locations (company_id, kind, address, country)
           values ($1,'office',$2,'PH')`,
          [companyId, c.ph_presence],
        );
      }
    }

    for (const p of c.contacts ?? []) {
      if (!p.email && !p.name) continue;
      if (p.email) {
        await client.query(
          `insert into contacts (company_id, full_name, title, email, phone)
           values ($1,$2,$3,$4,$5)
           on conflict (company_id, email) do update set
             full_name=coalesce(excluded.full_name, contacts.full_name),
             title=coalesce(excluded.title, contacts.title),
             phone=coalesce(excluded.phone, contacts.phone)`,
          [companyId, p.name ?? null, p.title ?? null, p.email, p.phone ?? null],
        );
      } else {
        await client.query(
          `insert into contacts (company_id, full_name, title, phone)
           select $1,$2,$3,$4 where not exists
             (select 1 from contacts where company_id=$1 and full_name=$2)`,
          [companyId, p.name, p.title ?? null, p.phone ?? null],
        );
      }
      counts.contacts++;
    }

    // Email-sourced rows are owned by this import: replace them.
    await client.query("delete from offers where company_id=$1 and source='email'", [companyId]);
    await client.query("delete from interactions where company_id=$1 and channel='email'", [companyId]);
    await client.query(
      'delete from documents where company_id=$1 and gmail_thread_id = any($2)',
      [companyId, c.thread_ids ?? []],
    );

    for (const p of c.products ?? []) {
      const name = [p.name, p.model].filter(Boolean).join(' — ') || 'unnamed';
      await client.query(
        `insert into offers (company_id, raw_product_name, price, currency, price_basis,
           source, source_ref, observed_on, notes)
         values ($1,$2,$3,$4,$5,'email',$6,coalesce($7::date, current_date),$8)`,
        [companyId, name, p.price ?? null, (p.currency ?? 'PHP').slice(0, 3).toUpperCase(),
          oneOf(String(p.price_basis ?? '').toLowerCase(), BASES, 'unknown'),
          c.thread_ids?.[0] ?? null, c.last_contact ?? null,
          [p.category && `category: ${p.category}`, p.notes].filter(Boolean).join('; ') || null],
      );
      counts.offers++;
    }

    for (const t of new Set(c.thread_ids ?? [])) {
      await client.query(
        `insert into interactions (company_id, channel, direction, gmail_thread_id)
         values ($1,'email','inbound',$2)`,
        [companyId, t],
      );
      counts.interactions++;
    }

    for (const f of new Set(c.has_attachments ?? [])) {
      await client.query(
        `insert into documents (company_id, kind, filename, gmail_thread_id)
         values ($1,$2,$3,$4)`,
        [companyId, docKind(f), f, c.thread_ids?.[0] ?? null],
      );
      counts.documents++;
    }
    await client.query('commit');
  } catch (err) {
    await client.query('rollback');
    console.error(`skipped ${c.company}: ${err.message}`);
    process.exitCode = 1;
  }
}
await client.end();
console.log(counts);
