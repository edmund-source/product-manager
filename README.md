# product-manager

Helios view of the products we distribute and the market around them: which
vendors sell (or pitch) to us, what they carry, at what price, and where.

- Database: Postgres (hosted on Supabase). Schema in `supabase/migrations/`.
- Designed to link to Hyperion: `products` map to Hyperion `skuCode`s via
  `product_hyperion_skus`, `companies.hyperion_supplier_id` matches Hyperion's
  procurement supplier id, and `product_categories` mirrors Hyperion's
  inventory categories. Hyperion is read-only from this project.

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
email-sourced offers, interactions and documents are replaced.

To (re)build the extract, run `/supplier-sweep` in Claude Code inside this
repo (`/supplier-sweep 2026/10/22` sweeps only newer mail). See
`.claude/skills/supplier-sweep/SKILL.md`.
