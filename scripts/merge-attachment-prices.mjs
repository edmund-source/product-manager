// Merges prices read from email attachments (data/attachment_prices.json, one
// object per file) into the Gmail supplier extract, so `import:gmail` loads
// them as partner price lists. Each file is matched to a company by thread,
// message, sender domain, sender email or company name; files that match nobody become a
// new company entry. Safe to re-run: attachment lines are replaced.
//
//   node scripts/merge-attachment-prices.mjs data/suppliers_from_gmail.json \
//     data/attachment_prices.json data/suppliers_merged.json
import { readFile, writeFile } from 'node:fs/promises';

const [suppliersFile = 'data/suppliers_from_gmail.json',
  attachmentsFile = 'data/attachment_prices.json',
  outFile = 'data/suppliers_merged.json'] = process.argv.slice(2);

const companies = JSON.parse(await readFile(suppliersFile, 'utf8'));
const docs = JSON.parse(await readFile(attachmentsFile, 'utf8'));

const lower = (s) => (s ? String(s).toLowerCase().trim() : null);
const FREE_MAIL = ['gmail.com', 'yahoo.com', 'outlook.com', 'hotmail.com', 'qq.com', '163.com'];
const CATEGORY_TO_TYPE = {
  inverters: 'inverters', panels: 'panels', batteries: 'batteries', mounting: 'mounting',
  bos: 'bos', ev_charging: 'ev_charging', appliances: 'appliances', financing: 'consumer_financing',
  insurance: 'insurance', payments: 'payments', software: 'software', service: 'services',
};

for (const c of companies) {
  c.products = (c.products ?? []).filter((p) => !/^attachment:/i.test(p.source ?? ''));
}

const findCompany = (d) => {
  const domain = lower(d.sender_domain) ?? lower(d.sender_email)?.split('@')[1];
  const email = lower(d.sender_email);
  return companies.find((c) => (c.thread_ids ?? []).includes(d.thread_id))
    ?? companies.find((c) => (c.attachment_messages ?? []).some((m) => m.message_id === d.message_id))
    ?? (domain && !FREE_MAIL.includes(domain)
      ? companies.find((c) => lower(c.website_domain)?.replace(/^www\./, '') === domain)
      : undefined)
    ?? (email ? companies.find((c) => (c.contacts ?? []).some((p) => lower(p.email) === email)) : undefined)
    ?? (d.company ? companies.find((c) => lower(c.company) === lower(d.company)) : undefined);
};

const stats = { files: docs.length, matched: 0, added_companies: 0, lines: 0, priced: 0 };
for (const d of docs) {
  let c = findCompany(d);
  const isNew = !c;
  if (c) {
    stats.matched++;
  } else {
    const domain = lower(d.sender_domain);
    c = {
      company: d.company ?? d.sender_email ?? d.filename,
      website_domain: domain && !FREE_MAIL.includes(domain) ? domain : null,
      kind: d.kind ?? 'other', country: d.country ?? null, solar_related: true, partner_types: [], brands: [], products: [],
      contacts: d.sender_email ? [{ name: null, title: null, email: d.sender_email }] : [],
      status: 'quoted', first_contact: d.message_date ?? null, last_contact: d.message_date ?? null,
      thread_ids: d.thread_id ? [d.thread_id] : [], has_attachments: [],
      summary: d.thread_id ? `Found only through the attachment ${d.filename}.` : `Known from the price list ${d.filename}.`,
    };
    companies.push(c);
    stats.added_companies++;
  }
  c.has_attachments = [...new Set([...(c.has_attachments ?? []), d.filename])];
  if (d.thread_id && !(c.thread_ids ?? []).includes(d.thread_id)) {
    c.thread_ids = [...(c.thread_ids ?? []), d.thread_id];
  }
  for (const p of d.products ?? []) {
    // rebates and marketing incentives are not equipment prices
    const category = /rebate|incentive/i.test(p.name ?? '') ? 'service' : p.category ?? null;
    c.products.push({
      name: p.name, model: p.model ?? null, category,
      price: p.price ?? null, currency: p.currency ?? d.currency ?? null,
      price_basis: p.price_basis ?? d.price_basis ?? null,
      vat_included: p.vat_included ?? d.vat_included ?? null,
      unit: p.unit ?? 'piece', min_qty: p.min_qty ?? 1,
      quoted_on: d.document_date ?? d.message_date ?? null, valid_until: d.valid_until ?? null,
      thread_id: d.thread_id ?? null, source: `attachment: ${d.filename}`,
      specs: p.specs ?? null,
      notes: [p.brand && `brand: ${p.brand}`, p.notes, d.terms].filter(Boolean).join('; ') || null,
    });
    if (p.brand && !(c.brands ?? []).includes(p.brand)) c.brands = [...(c.brands ?? []), p.brand];
    const type = CATEGORY_TO_TYPE[p.category];
    // Tag companies known only from an attachment; leave the sweep's tags alone.
    if (type && (isNew || !c.partner_types?.length) && !(c.partner_types ?? []).includes(type)) {
      c.partner_types = [...(c.partner_types ?? []), type];
    }
    stats.lines++;
    if (p.price != null) stats.priced++;
  }
  if (!c.partner_types?.length) c.partner_types = ['other'];
}

await writeFile(outFile, JSON.stringify(companies, null, 2));
console.log({ ...stats, companies: companies.length, out: outFile });
