// Turns business cards saved from the partner explorer (the artifact's `cards`
// collection, read with ArtifactData) into supplier-extract records that
// merge-incremental.mjs folds in. A new company starts as potential_partner.
// A card for a company already in the list carries no contact date, so the
// merge adds its people, brands and types without touching stage or summary.
//
//   node scripts/cards-to-suppliers.mjs <cards.json> <out.json>
//
// cards.json: an array of card documents, either plain objects or {id, data}.
import { readFile, writeFile } from 'node:fs/promises';

const [cardsFile, outFile] = process.argv.slice(2);
const raw = JSON.parse(await readFile(cardsFile, 'utf8'));
const docs = (Array.isArray(raw) ? raw : raw.documents ?? raw.docs ?? [])
  .map((d) => ({ id: d.id ?? d.doc_id ?? null, ...(d.data ?? d) }))
  .filter((c) => c.company && !c.loaded);

const out = docs.map((c) => {
  const day = String(c.created_at ?? '').slice(0, 10) || null;
  const where = [c.met_at && `met at ${c.met_at}`, c.note].filter(Boolean).join('; ');
  const known = Boolean(c.matched_company);
  return {
    company: known ? c.matched_company : c.company,
    website_domain: c.website_domain || null,
    country: c.country || null,
    ph_presence: c.ph_presence || null,
    kind: c.kind || 'other',
    solar_related: true,
    partner_types: c.partner_types?.length ? c.partner_types : ['other'],
    brands: c.brands ?? [],
    products: c.products ? [{ name: c.products, model: null, category: null, price: null, currency: null, price_basis: null, notes: 'from business card', source: 'business_card' }] : [],
    contacts: (c.contacts ?? []).map((p) => ({ name: p.name ?? null, title: p.title ?? null, email: p.email ?? null, phone: p.phone ?? null })),
    introduced_by: c.met_at ? `Business card (${c.met_at})` : 'Business card',
    status: 'potential_partner', // ignored for a known company: its record is newer
    first_contact: known ? null : day,
    last_contact: known ? null : day,
    thread_ids: [], has_attachments: [],
    summary: `Business card saved ${day ?? ''}${where ? ` (${where})` : ''}.${c.products ? ` Offers: ${c.products}.` : ''}`.replace(' .', '.'),
    next_step: 'Follow up from the business card.',
    card_ids: c.id ? [c.id] : [],
  };
});
await writeFile(outFile, JSON.stringify(out, null, 1));
console.log({ cards: docs.length, new_companies: docs.filter((c) => !c.matched_company).length, existing: docs.filter((c) => c.matched_company).length, out: outFile });
