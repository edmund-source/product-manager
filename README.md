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

Re-running is safe: companies, brands and contacts are upserted, and the
email-sourced prices (`partner_email`), interactions and documents are
replaced.

To (re)build the extract, run `/supplier-sweep` in Claude Code inside this
repo (`/supplier-sweep 2026/10/22` sweeps only newer mail). See
`.claude/skills/supplier-sweep/SKILL.md`.
