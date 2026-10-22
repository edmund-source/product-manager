-- Vendor & product register for Helios product-manager.
-- Plain Postgres (runs on Supabase or any PG >= 15). Field names follow
-- Hyperion's API where an equivalent exists (skuCode -> sku_code, brand,
-- category, supplier id) so rows can be linked back without translation.

create extension if not exists pgcrypto;
create extension if not exists citext;

create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Mirrors Hyperion inventory categories; extra rows for non-stock vendors.
create table product_categories (
  key        text primary key,
  label      text not null,
  hyperion_category text,            -- exact Hyperion label, null if none
  solar      boolean not null default true
);

insert into product_categories (key, label, hyperion_category, solar) values
  ('inverters',   'Inverters',          'Inverters',          true),
  ('panels',      'Panels',             'Panels',             true),
  ('batteries',   'Batteries',          'Batteries',          true),
  ('mounting',    'Mounting',           'Mounting',           true),
  ('bos',         'BOS — Electrical',   'BOS — Electrical',   true),
  ('ats',         'ATS',                'ATS',                true),
  ('consumables', 'Consumables',        'Consumables',        true),
  ('ev_charging', 'EV charging',        null,                 true),
  ('appliances',  'Appliances',         null,                 false),
  ('software',    'Software / SaaS',    null,                 false),
  ('logistics',   'Logistics',          null,                 false),
  ('services',    'Services',           null,                 false),
  ('financing',   'Financing',          null,                 false),
  ('events',      'Events',             null,                 false),
  ('other',       'Other',              null,                 false);

-- A company that sells, or is trying to sell, to Helios.
create table companies (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  legal_name       text,
  website_domain   citext unique,
  country          text,
  kind             text not null default 'other' check (kind in
                     ('manufacturer','distributor','wholesaler','installer',
                      'service','software','logistics','financing','event','other')),
  solar_related    boolean not null default true,
  status           text not null default 'cold_inbound' check (status in
                     ('cold_inbound','intro','in_discussion','quoted','meeting_held',
                      'accredited','active_supplier','declined','dormant','unknown')),
  priority         smallint check (priority between 1 and 3),  -- 1 = high
  hyperion_supplier_id text unique,  -- Hyperion procurement supplier id, e.g. '22'
  introduced_by    text,
  summary          text,
  first_contact_on date,
  last_contact_on  date,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index companies_name_key on companies (lower(name));
create trigger companies_updated before update on companies
  for each row execute function set_updated_at();

create table company_categories (
  company_id   uuid not null references companies on delete cascade,
  category_key text not null references product_categories,
  primary key (company_id, category_key)
);

-- Offices, warehouses, showrooms. Drives "where is it offered".
create table company_locations (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies on delete cascade,
  kind        text not null default 'office' check (kind in
                ('hq','office','warehouse','showroom','factory','other')),
  address     text,
  city        text,
  province    text,
  country     text not null default 'PH',
  created_at  timestamptz not null default now()
);
create index on company_locations (company_id);
create index on company_locations (country, province, city);

create table contacts (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references companies on delete cascade,
  full_name   text,
  title       text,
  email       citext,
  phone       text,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (company_id, email)
);
create trigger contacts_updated before update on contacts
  for each row execute function set_updated_at();

create table brands (
  id    uuid primary key default gen_random_uuid(),
  name  citext not null unique,                  -- matches Hyperion `brand`
  manufacturer_company_id uuid references companies on delete set null
);

-- Which companies make or carry which brands.
create table company_brands (
  company_id   uuid not null references companies on delete cascade,
  brand_id     uuid not null references brands on delete cascade,
  relationship text not null default 'unknown' check (relationship in
                 ('manufacturer','authorized_distributor','reseller','unknown')),
  primary key (company_id, brand_id)
);

-- One row per real model. Several Hyperion SKUs can map to one product.
create table products (
  id             uuid primary key default gen_random_uuid(),
  brand_id       uuid references brands on delete set null,
  category_key   text not null references product_categories,
  model_code     text,                         -- manufacturer model, e.g. SUN-6K-SG04LP1-EU
  name           text not null,
  -- Inverter fields; null for other categories.
  inverter_type  text check (inverter_type in ('hybrid','grid_tied','off_grid','micro')),
  rated_kw       numeric(8,3),
  phase          smallint check (phase in (1,3)),
  battery_voltage text check (battery_voltage in ('low','high')),
  specs          jsonb not null default '{}',  -- everything else from the datasheet
  datasheet_url  text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (brand_id, model_code)
);
create index on products (category_key);
create trigger products_updated before update on products
  for each row execute function set_updated_at();

create table product_hyperion_skus (
  sku_code    text primary key,                -- Hyperion skuCode, e.g. INV-0001
  product_id  uuid not null references products on delete cascade
);

-- A price seen for a product from a seller at a point in time.
-- Never updated in place: a new price is a new row, so history is kept.
create table offers (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid not null references companies on delete cascade,
  product_id       uuid references products on delete set null,
  raw_product_name text not null,              -- as the seller wrote it
  price            numeric(14,2),
  currency         char(3) not null default 'PHP',
  price_basis      text check (price_basis in
                     ('exw','fob','cif','ddp','delivered','retail','wholesale','unknown')),
  vat_included     boolean,
  moq              integer,
  city             text,
  province         text,
  country          text default 'PH',
  source           text not null check (source in
                     ('email','website','marketplace','call','manual')),
  source_ref       text,                       -- Gmail thread id or URL
  observed_on      date not null default current_date,
  valid_until      date,
  notes            text,
  created_at       timestamptz not null default now()
);
create index on offers (product_id, observed_on desc);
create index on offers (company_id);

-- Emails, meetings, calls with a company.
create table interactions (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references companies on delete cascade,
  occurred_on     date not null,
  channel         text not null check (channel in ('email','meeting','call','event','other')),
  direction       text check (direction in ('inbound','outbound')),
  subject         text,
  summary         text,
  gmail_thread_id text,
  created_at      timestamptz not null default now(),
  unique (company_id, gmail_thread_id)
);
create index on interactions (company_id, occurred_on desc);

-- Price lists, brochures, certificates received.
create table documents (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references companies on delete cascade,
  kind            text not null default 'other' check (kind in
                    ('price_list','brochure','company_profile','datasheet',
                     'certificate','contract','other')),
  filename        text not null,
  storage_path    text,                        -- Supabase Storage key once uploaded
  gmail_thread_id text,
  received_on     date,
  created_at      timestamptz not null default now()
);
create index on documents (company_id);

-- Latest price per (product, seller, location): the comparison view.
create view latest_offers as
select distinct on (o.product_id, o.company_id, coalesce(o.province, ''), coalesce(o.city, ''))
       o.*, c.name as company_name, p.name as product_name, p.model_code,
       b.name as brand, p.category_key, p.rated_kw, p.inverter_type
from offers o
join companies c on c.id = o.company_id
left join products p on p.id = o.product_id
left join brands b on b.id = p.brand_id
order by o.product_id, o.company_id, coalesce(o.province, ''), coalesce(o.city, ''),
         o.observed_on desc, o.created_at desc;
