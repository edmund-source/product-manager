-- Equipment prices, kept in their own schema. Three source groups:
--   hyperion  what Helios paid (POs, stock cost) and sells at — from Hyperion
--   partner   what partners quote us — emails, price lists, calls
--   market    what anyone asks publicly — FB Marketplace, Shopee, …
-- A price list is one quote / PO / scrape; equipment_prices are its lines.
-- Rows are never updated in place: a new price is a new row, so history is kept.
-- Replaces public.offers.

create schema pricing;

create table pricing.source_types (
  key        text primary key,
  label      text not null,
  grp        text not null check (grp in ('hyperion','partner','market')),
  price_kind text not null check (price_kind in ('actual_cost','selling','quote','asking')),
  active     boolean not null default true,   -- false until a feed loads this source
  sort_order smallint not null
);

insert into pricing.source_types (key, label, grp, price_kind, active, sort_order) values
  ('hyperion_po',        'Hyperion purchase order',    'hyperion', 'actual_cost', false, 10),
  ('hyperion_stock',     'Hyperion stock cost (FIFO)', 'hyperion', 'actual_cost', false, 20),
  ('hyperion_selling',   'Hyperion selling price',     'hyperion', 'selling',     false, 30),
  ('partner_email',      'Partner email quote',        'partner',  'quote',       true,  110),
  ('partner_price_list', 'Partner price list file',    'partner',  'quote',       true,  120),
  ('partner_website',    'Partner website',            'partner',  'quote',       true,  130),
  ('partner_call',       'Call / meeting',             'partner',  'quote',       true,  140),
  ('partner_other',      'Other partner source',       'partner',  'quote',       true,  150),
  ('fb_marketplace',     'Facebook Marketplace',       'market',   'asking',      false, 210),
  ('shopee',             'Shopee',                     'market',   'asking',      false, 220),
  ('lazada',             'Lazada',                     'market',   'asking',      false, 230),
  ('competitor_site',    'Competitor website',         'market',   'asking',      false, 240),
  ('market_other',       'Other market source',        'market',   'asking',      false, 290);

create table pricing.price_lists (
  id           uuid primary key default gen_random_uuid(),
  source_type  text not null references pricing.source_types,
  company_id   uuid references public.companies on delete cascade,  -- required for partner sources
  seller_name  text,                   -- market: seller / shop name as shown
  external_ref text,                   -- Gmail thread id, Hyperion PO no., listing id or URL
  document_id  uuid references public.documents on delete set null,
  currency     char(3) not null default 'PHP',
  price_basis  text check (price_basis in
                 ('exw','fob','cif','ddp','delivered','retail','wholesale','unknown')),
  vat_included boolean,                -- null = not stated
  city         text,
  province     text,
  country      text default 'PH',
  quoted_on    date not null,
  valid_until  date,
  notes        text,
  created_at   timestamptz not null default now()
);
create index on pricing.price_lists (company_id);
create index on pricing.price_lists (source_type, external_ref);

-- Partner prices need the partner; market prices need some seller identity.
create function pricing.check_price_list_seller() returns trigger
language plpgsql as $$
declare g text;
begin
  select grp into g from pricing.source_types where key = new.source_type;
  if g = 'partner' and new.company_id is null then
    raise exception 'partner price list needs company_id';
  end if;
  if g = 'market' and new.company_id is null and new.seller_name is null
     and new.external_ref is null then
    raise exception 'market price list needs company_id, seller_name or external_ref';
  end if;
  return new;
end $$;
create trigger price_lists_seller before insert or update on pricing.price_lists
  for each row execute function pricing.check_price_list_seller();

create table pricing.equipment_prices (
  id                uuid primary key default gen_random_uuid(),
  price_list_id     uuid not null references pricing.price_lists on delete cascade,
  product_id        uuid references public.products on delete set null,  -- null until matched
  raw_product_name  text not null,     -- as the seller wrote it
  raw_model_code    text,
  hyperion_sku_code text,              -- Hyperion rows; matched to a product automatically
  price             numeric(14,4),     -- 4 dp for per-watt quotes; null = price not stated (e.g. in a PDF)
  unit              text not null default 'piece' check (unit in
                      ('piece','set','watt','kwh','meter','roll','box')),
  min_qty           integer not null default 1,   -- volume tiers: one row per tier
  condition         text not null default 'new' check (condition in
                      ('new','used','refurbished','unknown')),
  listing_url       text,
  notes             text,
  created_at        timestamptz not null default now()
);
create index on pricing.equipment_prices (product_id);
create index on pricing.equipment_prices (price_list_id);

create function pricing.match_hyperion_sku() returns trigger
language plpgsql as $$
begin
  if new.product_id is null and new.hyperion_sku_code is not null then
    select product_id into new.product_id
    from public.product_hyperion_skus where sku_code = new.hyperion_sku_code;
  end if;
  return new;
end $$;
create trigger equipment_prices_match_sku before insert on pricing.equipment_prices
  for each row execute function pricing.match_hyperion_sku();

-- PHP per unit of foreign currency, for quotes in USD, CNY, …
create table pricing.fx_rates (
  currency     char(3) not null,
  rate_date    date not null,
  php_per_unit numeric(12,6) not null,
  primary key (currency, rate_date)
);

-- Carry over public.offers: one price list per seller, source and quote date.
create temp table offer_lists on commit drop as
select gen_random_uuid() as id, company_id, source, source_ref, observed_on, currency,
       price_basis, vat_included, city, province, country, valid_until
from public.offers
group by company_id, source, source_ref, observed_on, currency, price_basis,
         vat_included, city, province, country, valid_until;

insert into pricing.price_lists (id, source_type, company_id, external_ref, currency,
  price_basis, vat_included, city, province, country, quoted_on, valid_until)
select id,
       case source when 'email' then 'partner_email' when 'website' then 'partner_website'
                   when 'call' then 'partner_call' when 'marketplace' then 'market_other'
                   else 'partner_other' end,
       company_id, source_ref, currency, price_basis, vat_included, city, province,
       country, observed_on, valid_until
from offer_lists;

insert into pricing.equipment_prices (price_list_id, product_id, raw_product_name,
  price, min_qty, notes, created_at)
select l.id, o.product_id, o.raw_product_name, o.price, coalesce(o.moq, 1), o.notes, o.created_at
from public.offers o
join offer_lists l on l.company_id = o.company_id and l.source = o.source
  and l.observed_on = o.observed_on and l.currency = o.currency
  and l.source_ref is not distinct from o.source_ref
  and l.price_basis is not distinct from o.price_basis
  and l.vat_included is not distinct from o.vat_included
  and l.city is not distinct from o.city
  and l.province is not distinct from o.province
  and l.country is not distinct from o.country
  and l.valid_until is not distinct from o.valid_until;

drop table public.offers;

-- Every priced line in PHP excluding VAT, with per-W / per-kWh / per-kW
-- figures where the product's specs allow it.
create view pricing.normalized_prices as
select ep.id, ep.price_list_id, ep.product_id, ep.raw_product_name, ep.hyperion_sku_code,
       ep.unit, ep.min_qty, ep.condition, ep.listing_url, ep.created_at,
       pl.source_type, st.grp as source_group, st.price_kind,
       pl.company_id, coalesce(c.name, pl.seller_name,
                case when st.grp = 'hyperion' then 'Helios (Hyperion)' end) as seller,
       pl.external_ref, pl.quoted_on, pl.valid_until, pl.price_basis,
       pl.city, pl.province, pl.country,
       p.name as product_name, p.model_code, p.category_key,
       ep.price as price_original, pl.currency, pl.vat_included,
       n.unit_php_ex_vat,
       round(case ep.unit when 'watt' then n.unit_php_ex_vat
                    when 'piece' then n.unit_php_ex_vat / nullif(pe.wattage_w, 0) end, 2) as php_per_w,
       round(case ep.unit when 'kwh' then n.unit_php_ex_vat
                    when 'piece' then n.unit_php_ex_vat / nullif(pe.capacity_kwh, 0) end, 2) as php_per_kwh,
       round(case ep.unit when 'piece' then n.unit_php_ex_vat / nullif(pe.rated_kw, 0) end, 2) as php_per_kw
from pricing.equipment_prices ep
join pricing.price_lists pl on pl.id = ep.price_list_id
join pricing.source_types st on st.key = pl.source_type
left join public.companies c on c.id = pl.company_id
left join public.products p on p.id = ep.product_id
left join public.product_equipment pe on pe.product_id = ep.product_id
left join lateral (
  select php_per_unit from pricing.fx_rates
  where currency = pl.currency and rate_date <= pl.quoted_on
  order by rate_date desc limit 1
) fx on pl.currency <> 'PHP'
cross join lateral (
  select round(ep.price
               * case when pl.currency = 'PHP' then 1 else fx.php_per_unit end
               / case when pl.vat_included then 1.12 else 1 end, 2) as unit_php_ex_vat
) n
where ep.price is not null;

-- Newest price per item, source, seller, condition, quantity tier and location.
create view pricing.latest_prices as
select distinct on (coalesce(product_id::text, lower(raw_product_name)), source_type,
                    coalesce(company_id::text, lower(seller)), condition, min_qty,
                    coalesce(province, ''), coalesce(city, ''))
       *
from pricing.normalized_prices
order by coalesce(product_id::text, lower(raw_product_name)), source_type,
         coalesce(company_id::text, lower(seller)), condition, min_qty,
         coalesce(province, ''), coalesce(city, ''), quoted_on desc, created_at desc;

-- One row per product: Hyperion cost and selling price next to partner quotes
-- and market asking prices. All figures PHP excluding VAT.
create view pricing.price_benchmarks as
select product_id, max(product_name) as product_name, max(model_code) as model_code,
       max(category_key) as category_key,
       (array_agg(unit_php_ex_vat order by quoted_on desc, created_at desc)
          filter (where source_type = 'hyperion_po'))[1]       as hyperion_last_po_cost,
       max(quoted_on) filter (where source_type = 'hyperion_po') as hyperion_last_po_on,
       (array_agg(unit_php_ex_vat order by quoted_on desc, created_at desc)
          filter (where source_type = 'hyperion_stock'))[1]    as hyperion_stock_cost,
       (array_agg(unit_php_ex_vat order by quoted_on desc, created_at desc)
          filter (where source_type = 'hyperion_selling'))[1]  as hyperion_selling_price,
       min(unit_php_ex_vat) filter (where recent and source_group = 'partner'
                                    and condition = 'new')     as partner_best_quote_90d,
       (array_agg(seller order by unit_php_ex_vat)
          filter (where recent and source_group = 'partner'
                  and condition = 'new'))[1]                   as partner_best_seller,
       count(*) filter (where recent and source_group = 'partner') as partner_quotes_90d,
       percentile_cont(0.5) within group (order by unit_php_ex_vat)
         filter (where recent and source_group = 'market'
                 and condition = 'new')                        as market_new_median_90d,
       count(*) filter (where recent and source_group = 'market'
                        and condition = 'new')                 as market_new_listings_90d,
       percentile_cont(0.5) within group (order by unit_php_ex_vat)
         filter (where recent and source_group = 'market'
                 and condition in ('used','refurbished'))      as market_used_median_90d,
       count(*) filter (where recent and source_group = 'market'
                        and condition in ('used','refurbished')) as market_used_listings_90d
from (select *, quoted_on >= current_date - 90 as recent from pricing.normalized_prices) np
where product_id is not null
group by product_id;

-- Lines still to be matched to a product (review queue), and quotes whose
-- price wasn't stated (usually inside an attachment).
create view pricing.unmatched_prices as
select ep.*, pl.source_type, pl.company_id, pl.seller_name, pl.external_ref, pl.quoted_on
from pricing.equipment_prices ep
join pricing.price_lists pl on pl.id = ep.price_list_id
where ep.product_id is null or ep.price is null;
