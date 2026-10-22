# product-manager

Helios view of the products we distribute and the market around them: which
vendors sell (or pitch) to us, what they carry, at what price, and where.

- Database: Postgres (hosted on Supabase). Schema in `supabase/migrations/`.
- Designed to link to Hyperion: `products` map to Hyperion `skuCode`s via
  `product_hyperion_skus`, `companies.hyperion_supplier_id` matches Hyperion's
  procurement supplier id, and `product_categories` mirrors Hyperion's
  inventory categories. Hyperion is read-only from this project.

## Setup

    cp .env.example .env   # fill in DATABASE_URL
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/20261022000000_vendor_register.sql
