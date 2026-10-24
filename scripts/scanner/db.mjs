// Database side of the weekly supplier inbox scanner
// (.claude/skills/supplier-inbox-scan). Writes into the live Supabase tables:
// companies, company_partner_types, contacts, interactions, documents,
// offer_candidates and scanner_runs. Needs DATABASE_URL.
//
//   node scripts/scanner/db.mjs companies                 # JSON of companies for matching
//   node scripts/scanner/db.mjs run-start <classify|extract>  # prints the run id and the last finished run
//   node scripts/scanner/db.mjs run-finish <run_id> <summary.json>
//   node scripts/scanner/db.mjs last <classify|extract>   # last finished run + pending candidates
//   node scripts/scanner/db.mjs classify <classified.json>    # upsert companies, contacts, emails
//   node scripts/scanner/db.mjs extract <extracted.json>      # documents + pending offer candidates
//
// Extracted prices never become offers here: they wait in offer_candidates
// (status pending) until Edmund approves them.
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
const q = (sql, params) => client.query(sql, params);
const readJson = async (f) => JSON.parse(await readFile(f, 'utf8'));
const lower = (s) => (s ? String(s).toLowerCase().trim() : null);
const domainOf = (s) => lower(s)?.replace(/^https?:\/\//, '').replace(/^www\./, '').replace(/\/.*$/, '') || null;
const FREE_MAIL = ['gmail.com', 'yahoo.com', 'outlook.com', 'hotmail.com', 'qq.com', '163.com', '126.com', 'icloud.com'];
const KINDS = ['manufacturer', 'distributor', 'wholesaler', 'installer', 'service', 'software', 'logistics',
  'financing', 'bank', 'lender', 'investor', 'insurer', 'event', 'other'];
const STATUSES = ['cold_inbound', 'intro', 'in_discussion', 'quoted', 'meeting_held', 'accredited',
  'active_supplier', 'declined', 'dormant', 'unknown'];
const DOC_KINDS = ['price_list', 'brochure', 'company_profile', 'datasheet', 'certificate', 'contract', 'other'];
const BASES = ['exw', 'fob', 'cif', 'ddp', 'delivered', 'retail', 'wholesale', 'unknown'];
const oneOf = (v, list, dflt) => (list.includes(v) ? v : dflt);
const day = (v) => (v && /^\d{4}-\d{2}-\d{2}/.test(String(v)) ? String(v).slice(0, 10) : null);
const num = (v) => (v == null || v === '' || Number.isNaN(Number(v)) ? null : Number(v));

const out = {};
try {
  if (cmd === 'companies') {
    const { rows } = await q(`select c.id, c.name, c.website_domain::text as domain, c.status, c.kind, c.drive_folder_id,
        coalesce(array_agg(distinct lower(ct.email::text)) filter (where ct.email is not null), '{}') as emails,
        coalesce(array_agg(distinct pt.partner_type_key) filter (where pt.partner_type_key is not null), '{}') as partner_types
      from companies c left join contacts ct on ct.company_id = c.id left join company_partner_types pt on pt.company_id = c.id
      group by c.id order by c.name`);
    out.companies = rows;
  } else if (cmd === 'run-start') {
    const phase = oneOf(arg1, ['classify', 'extract'], null);
    if (!phase) throw new Error('phase must be classify or extract');
    const last = await q(`select id, started_at, finished_at, summary from scanner_runs
      where phase = $1 and finished_at is not null order by started_at desc limit 1`, [phase]);
    const { rows } = await q('insert into scanner_runs (phase) values ($1) returning id, started_at', [phase]);
    Object.assign(out, { run: rows[0], last_finished: last.rows[0] ?? null });
  } else if (cmd === 'last') {
    const { rows } = await q(`select id, started_at, finished_at, summary from scanner_runs
      where phase = $1 and finished_at is not null order by started_at desc limit 1`, [arg1]);
    out.last_finished = rows[0] ?? null;
    out.pending_candidates = Number((await q("select count(*) from offer_candidates where status = 'pending'")).rows[0].count);
  } else if (cmd === 'run-finish') {
    const summary = arg2 ? await readJson(arg2) : {};
    await q('update scanner_runs set finished_at = now(), summary = $2 where id = $1', [arg1, summary]);
    out.finished = arg1;
  } else if (cmd === 'classify') {
    // [{company_id?, name, website_domain, kind, status, partner_types[], introduced_by, summary,
    //   first_contact_on, last_contact_on, drive_folder_id, contacts[{full_name,title,email,phone}],
    //   emails[{gmail_thread_id, occurred_on, direction, subject, summary}]}]
    const recs = await readJson(arg1);
    out.companies = [];
    await q('begin');
    for (const r of recs) {
      const dom = domainOf(r.website_domain);
      const domain = dom && !FREE_MAIL.includes(dom) ? dom : null;
      let id = r.company_id ?? null;
      if (!id && domain) id = (await q('select id from companies where website_domain = $1', [domain])).rows[0]?.id ?? null;
      if (!id) id = (await q('select id from companies where lower(name) = lower($1) limit 1', [r.name])).rows[0]?.id ?? null;
      const created = !id;
      if (created) {
        id = (await q(`insert into companies (name, website_domain, country, kind, status, introduced_by, summary,
            first_contact_on, last_contact_on, drive_folder_id)
          values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) returning id`,
        [r.name, domain, r.country ?? null, oneOf(r.kind, KINDS, 'other'), oneOf(r.status, STATUSES, 'cold_inbound'),
          r.introduced_by ?? null, r.summary ?? null, day(r.first_contact_on), day(r.last_contact_on), r.drive_folder_id ?? null])).rows[0].id;
      } else {
        // never downgrade a stage or overwrite a summary someone wrote; fill gaps and move dates forward
        await q(`update companies set
            website_domain = coalesce(website_domain, $2),
            country = coalesce(country, $3),
            drive_folder_id = coalesce(drive_folder_id, $4),
            summary = coalesce(summary, $5),
            first_contact_on = least(coalesce(first_contact_on, $6::date), coalesce($6::date, first_contact_on)),
            last_contact_on = greatest(coalesce(last_contact_on, $7::date), coalesce($7::date, last_contact_on)),
            updated_at = now()
          where id = $1`,
        [id, domain, r.country ?? null, r.drive_folder_id ?? null, r.summary ?? null, day(r.first_contact_on), day(r.last_contact_on)]);
      }
      for (const t of r.partner_types ?? []) {
        await q(`insert into company_partner_types (company_id, partner_type_key)
          select $1, key from partner_types where key = $2 on conflict do nothing`, [id, t]);
      }
      for (const p of r.contacts ?? []) {
        if (!p.email && !p.full_name) continue;
        if (p.email) {
          await q(`insert into contacts (company_id, full_name, title, email, phone) values ($1,$2,$3,$4,$5)
            on conflict (company_id, email) do update set full_name = coalesce(contacts.full_name, excluded.full_name),
              title = coalesce(excluded.title, contacts.title), phone = coalesce(contacts.phone, excluded.phone), updated_at = now()`,
          [id, p.full_name ?? null, p.title ?? null, lower(p.email), p.phone ?? null]);
        } else if (!(await q('select 1 from contacts where company_id = $1 and lower(full_name) = lower($2)', [id, p.full_name])).rowCount) {
          await q('insert into contacts (company_id, full_name, title, phone) values ($1,$2,$3,$4)', [id, p.full_name, p.title ?? null, p.phone ?? null]);
        }
      }
      for (const m of r.emails ?? []) {
        if (!m.gmail_thread_id) continue;
        await q(`insert into interactions (company_id, occurred_on, channel, direction, subject, summary, gmail_thread_id)
          values ($1,$2,'email',$3,$4,$5,$6)
          on conflict (company_id, gmail_thread_id) do update set occurred_on = greatest(interactions.occurred_on, excluded.occurred_on),
            subject = excluded.subject, summary = coalesce(excluded.summary, interactions.summary)`,
        [id, day(m.occurred_on), oneOf(m.direction, ['inbound', 'outbound'], 'inbound'), m.subject ?? null, m.summary ?? null, m.gmail_thread_id]);
      }
      out.companies.push({ name: r.name, id, created });
    }
    await q('commit');
  } else if (cmd === 'extract') {
    // [{company_id, drive_file_id, filename, kind, gmail_thread_id, received_on, extraction_notes,
    //   lines[{brand_name, category_key, model_code, raw_product_name, specs, price, currency, price_basis,
    //          vat_included, moq, valid_until, observed_on, confidence, extraction_notes}]}]
    const docs = await readJson(arg1);
    const cats = new Set((await q('select key from product_categories')).rows.map((r) => r.key));
    out.documents = [];
    await q('begin');
    for (const d of docs) {
      const { rows } = await q(`insert into documents (company_id, kind, filename, storage_path, gmail_thread_id, received_on,
          drive_file_id, extracted_at, extraction_notes)
        values ($1,$2,$3,$4,$5,$6,$7,now(),$8)
        on conflict (drive_file_id) do update set kind = excluded.kind, extracted_at = now(), extraction_notes = excluded.extraction_notes
        returning id`,
      [d.company_id, oneOf(d.kind, DOC_KINDS, 'other'), d.filename, `drive:${d.drive_file_id}`, d.gmail_thread_id ?? null,
        day(d.received_on), d.drive_file_id, d.extraction_notes ?? null]);
      const docId = rows[0].id;
      // a re-read file replaces its own pending candidates; reviewed ones are kept
      await q("delete from offer_candidates where document_id = $1 and status = 'pending'", [docId]);
      let n = 0;
      for (const l of d.lines ?? []) {
        if (!l.raw_product_name) continue;
        const cur = l.currency && /^[A-Za-z]{3}$/.test(l.currency) ? l.currency.toUpperCase() : null;
        await q(`insert into offer_candidates (company_id, document_id, brand_name, category_key, model_code, raw_product_name,
            specs, price, currency, price_basis, vat_included, moq, valid_until, observed_on, confidence, extraction_notes)
          values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)`,
        [d.company_id, docId, l.brand_name ?? null, cats.has(l.category_key) ? l.category_key : null, l.model_code ?? null,
          String(l.raw_product_name).slice(0, 500), l.specs && typeof l.specs === 'object' ? l.specs : {}, num(l.price), cur,
          oneOf(l.price_basis, BASES, 'unknown'), typeof l.vat_included === 'boolean' ? l.vat_included : null,
          Number.isInteger(num(l.moq)) ? num(l.moq) : null, day(l.valid_until), day(l.observed_on) ?? day(d.received_on),
          oneOf(l.confidence, ['high', 'medium', 'low'], 'medium'), l.extraction_notes ?? null]);
        n++;
      }
      out.documents.push({ filename: d.filename, document_id: docId, candidates: n });
    }
    await q('commit');
  } else {
    throw new Error('command must be companies, run-start, run-finish, last, classify or extract');
  }
  console.log(JSON.stringify(out, null, 1));
} catch (e) {
  await q('rollback').catch(() => {});
  console.error(e.message);
  process.exitCode = 1;
} finally {
  await client.end();
}
