# product-manager

Helios view of the products we distribute and the market around them: which
vendors sell (or pitch) to us, what they carry, at what price, and where.

- Database: Postgres (hosted on Supabase). Schema in `supabase/migrations/`.
- Designed to link to Hyperion: `products` map to Hyperion `skuCode`s via
  `product_hyperion_skus`, `companies.hyperion_supplier_id` matches Hyperion's
  procurement supplier id, and `product_categories` mirrors Hyperion's
  inventory categories. Hyperion is read-only from this project.

## Catalog and prices

- **Catalog** (`public`): `products` are defined once — equipment by its
  manufacturer (`brand_id` + `model_code`), financing / insurance / service
  products by the partner that offers them (`provider_company_id`). Family
  fields sit in `product_equipment`, `product_financing`, `product_insurance`.
  `partner_products` says which partner offers which product; view
  `partner_catalog`. Loan rates per tenor go in `financing_terms`.
- **Equipment prices** (`pricing` schema): a `price_lists` row is one quote,
  PO or listing; `equipment_prices` are its lines. Never updated in place.
  Each list has a `source_type` in one of three groups:
  - `hyperion` — PO cost, stock cost (FIFO) and Helios selling price. Loaded
    from Hyperion; no sync yet, so these are empty for now. Lines carrying a
    `hyperion_sku_code` are matched to a product automatically.
  - `partner` — partner quotes; `partner_email` is filled by the Gmail import.
  - `market` — FB Marketplace, Shopee, Lazada, competitor sites. New, used and
    refurbished are kept apart (`condition`). Feeds to be built.
  `source_types.active` marks which sources have a live feed.
- Views: `pricing.normalized_prices` (PHP ex-VAT, ₱/W, ₱/kWh, ₱/kW; foreign
  currencies via `pricing.fx_rates`), `pricing.latest_prices`,
  `pricing.price_benchmarks` (per product: Hyperion cost and selling price,
  best partner quote, market medians), `pricing.unmatched_prices` (review
  queue). On Supabase, add `pricing` to the API's exposed schemas to query it
  over the REST API.

## Setup

    pnpm install
    cp .env.example .env              # set DATABASE_URL
    pnpm db:migrate                   # applies supabase/migrations/*.sql once each

Local Postgres instead of Supabase: create a database, run
`create extension pgcrypto; create extension citext;` in it as a superuser,
and point `DATABASE_URL` at it.

## Importing suppliers from Gmail

`data/suppliers_from_gmail.json` holds the vendor list extracted from Edmund's
mailbox (companies, brands, products and prices quoted, contacts, Gmail thread
ids). `data/` is git-ignored because it contains contact details.

    pnpm import:gmail data/suppliers_from_gmail.json

Prices read from attachments (PDF / XLSX price lists, one object per file in
`data/attachment_prices.json`) are merged in first, and load as
`partner_price_list` lists that name their file:

    pnpm merge:attachments data/suppliers_from_gmail.json data/attachment_prices.json data/suppliers_merged.json
    pnpm import:gmail data/suppliers_merged.json

`scripts/extract-gmail-attachments.py` turns a Gmail RAW message into files
and text (pdftotext, XLSX, DOCX) under `data/attachments/`.

Re-running is safe: companies, brands and contacts are upserted, and the
email-sourced prices (`partner_email`, `partner_price_list`), interactions and
documents are replaced.

To (re)build the extract, run `/supplier-sweep` in Claude Code inside this
repo (`/supplier-sweep 2026/10/22` sweeps only newer mail). See
`.claude/skills/supplier-sweep/SKILL.md`.

## Partner explorer

The partner explorer is a private claude.ai artifact built from the extracts
by `scripts/explorer/build.py` (page template in `scripts/explorer/template.html`).
Marie, the page's chat assistant, follows the plain-text instructions in
`scripts/explorer/marie.md`; edit that file to change how she answers.
She can also search and read the owner's Gmail, Drive and Google Chat, and
propose email drafts, Chat messages and business-card partners. Nothing is
saved or sent until the owner clicks the card's button. Saved cards wait in the
artifact's private `cards` store until the next refresh loads them
(`scripts/cards-to-suppliers.mjs`) as `potential_partner`. Only the artifact's
owner can use her.
A weekly routine refreshes it with only the mail since the last update; see
`.claude/skills/explorer-refresh/SKILL.md`. The artifact stores its own data
under `state/` with contact details removed (`scripts/explorer/scrub-state.py`),
and `scripts/merge-incremental.mjs` folds each week's delta into it.

## Supplier inbox scanner

A weekly cloud scanner (`.claude/skills/supplier-inbox-scan/SKILL.md`) finds
the week's supplier and distribution-candidate emails, matches them to
companies in the live Supabase database, gives each a Drive folder under
"Helios Suppliers", and puts lines from price lists into `offer_candidates`
for approval, then posts a summary in Google Chat. The Apps Script in
`scripts/drive-saver/Code.gs` (installed in Edmund's Google account) copies
the attachments into those folders hourly. Database writes go through
`scripts/scanner/db.mjs`, which needs `DATABASE_URL`.
