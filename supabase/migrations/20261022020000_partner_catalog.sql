-- Partner catalog: which partner offers which product, for every kind of
-- product (equipment, financing, insurance, services).
--
-- Products are defined once. Equipment is defined by its manufacturer and
-- carried by many partners (provider_company_id null). Financing, insurance
-- and service products are defined by the partner that offers them
-- (provider_company_id set). Fields specific to a product family live in a
-- 1:1 side table; everything else stays in products.specs.
-- Prices live in the `pricing` schema (next migration).

-- Product families decide which side table applies.
alter table product_categories add column family text not null default 'equipment'
  check (family in ('equipment','financing','insurance','service','software','other'));

update product_categories set family = case key
  when 'software'  then 'software'
  when 'logistics' then 'service'
  when 'services'  then 'service'
  when 'financing' then 'financing'
  when 'events'    then 'other'
  when 'other'     then 'other'
  else 'equipment' end;

insert into product_categories (key, label, hyperion_category, solar, family) values
  ('consumer_loan',  'Customer financing',  null, false, 'financing'),
  ('business_loan',  'Financing to Helios', null, false, 'financing'),
  ('insurance',      'Insurance',           null, false, 'insurance');

-- latest_offers reads the inverter columns moved below; pricing.latest_prices
-- replaces it in the next migration.
drop view latest_offers;

alter table products
  add column provider_company_id uuid references companies on delete cascade,
  add column description text,
  add column status text not null default 'active'
    check (status in ('active','discontinued','draft'));
create unique index products_provider_name_key on products (provider_company_id, lower(name))
  where provider_company_id is not null;

-- Equipment specs used for filtering and per-W / per-kWh / per-kW pricing.
create table product_equipment (
  product_id      uuid primary key references products on delete cascade,
  inverter_type   text check (inverter_type in ('hybrid','grid_tied','off_grid','micro')),
  rated_kw        numeric(8,3),
  phase           smallint check (phase in (1,3)),
  battery_voltage text check (battery_voltage in ('low','high')),
  capacity_kwh    numeric(8,3),          -- batteries
  wattage_w       integer,               -- panels, microinverters
  warranty_years  smallint
);

insert into product_equipment (product_id, inverter_type, rated_kw, phase, battery_voltage)
select id, inverter_type, rated_kw, phase, battery_voltage from products
where inverter_type is not null or rated_kw is not null or phase is not null
   or battery_voltage is not null;

alter table products
  drop column inverter_type, drop column rated_kw,
  drop column phase, drop column battery_voltage;

create table product_financing (
  product_id          uuid primary key references products on delete cascade,
  borrower            text not null check (borrower in ('customer','helios')),
  loan_type           text,              -- solar loan, salary loan, BNPL, lease, credit line…
  min_amount          numeric(14,2),
  max_amount          numeric(14,2),
  min_downpayment_pct numeric(5,2),
  collateral          text,
  eligibility         text
);

create table product_insurance (
  product_id     uuid primary key references products on delete cascade,
  coverage_type  text,                   -- all-risk, CGL, product liability…
  premium_basis  text                    -- % of system value, flat per year…
);

-- What each partner offers. The answer to "which products does partner X offer".
create table partner_products (
  company_id        uuid not null references companies on delete cascade,
  product_id        uuid not null references products on delete cascade,
  role              text not null default 'unknown' check (role in
                      ('manufacturer','authorized_distributor','reseller',
                       'lender','insurer','service_provider','unknown')),
  status            text not null default 'offered' check (status in
                      ('pitched','offered','accredited','in_use','discontinued')),
  coverage          text[],              -- provinces served; null = nationwide/unknown
  lead_time_days    integer,
  notes             text,
  first_seen_on     date,
  last_confirmed_on date,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (company_id, product_id)
);
create index on partner_products (product_id);
create trigger partner_products_updated before update on partner_products
  for each row execute function set_updated_at();

-- Financing rates per tenor. Never updated in place, like prices.
create table financing_terms (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null,
  product_id   uuid not null,
  tenor_months smallint not null,
  rate_pct     numeric(6,3) not null,
  rate_basis   text not null check (rate_basis in
                 ('add_on_monthly','effective_annual','flat')),
  fees         text,
  observed_on  date not null default current_date,
  source_ref   text,                     -- Gmail thread id, URL
  created_at   timestamptz not null default now(),
  foreign key (company_id, product_id) references partner_products on delete cascade
);
create index on financing_terms (product_id, tenor_months, observed_on desc);

-- One row per partner and product, for the catalog screen.
create view partner_catalog as
select pp.company_id, c.name as company_name, c.status as company_status,
       pp.product_id, p.name as product_name, p.model_code, b.name as brand,
       p.category_key, pc.family, pp.role, pp.status, pp.coverage,
       pp.lead_time_days, pp.last_confirmed_on,
       pe.inverter_type, pe.rated_kw, pe.capacity_kwh, pe.wattage_w,
       pf.borrower, pf.loan_type
from partner_products pp
join companies c on c.id = pp.company_id
join products p on p.id = pp.product_id
join product_categories pc on pc.key = p.category_key
left join brands b on b.id = p.brand_id
left join product_equipment pe on pe.product_id = p.id
left join product_financing pf on pf.product_id = p.id;
