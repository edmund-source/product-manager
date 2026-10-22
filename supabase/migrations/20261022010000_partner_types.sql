-- Partner types: what a company is to Helios (inverter supplier, panel
-- supplier, financing partner, ...). A company can have several. This
-- replaces company_categories, which tied companies to product categories;
-- product_categories stays for products and mirrors Hyperion.

create table partner_types (
  key        text primary key,
  label      text not null,
  grp        text not null check (grp in ('equipment','financial','services','other')),
  sort_order smallint not null
);

insert into partner_types (key, label, grp, sort_order) values
  ('inverters',          'Inverters',                 'equipment', 10),
  ('panels',             'Panels',                    'equipment', 20),
  ('batteries',          'Batteries',                 'equipment', 30),
  ('mounting',           'Mounting',                  'equipment', 40),
  ('bos',                'BOS — Electrical',          'equipment', 50),
  ('equipment',          'Equipment (general)',       'equipment', 60),
  ('ev_charging',        'EV charging',               'equipment', 70),
  ('appliances',         'Appliances',                'equipment', 80),
  ('consumer_financing', 'Customer financing',        'financial', 110),
  ('business_financing', 'Financing to Helios',       'financial', 120),
  ('investment',         'Investment (equity)',       'financial', 130),
  ('insurance',          'Insurance',                 'financial', 140),
  ('payments',           'Payments',                  'financial', 150),
  ('software',           'Software / SaaS',           'services', 210),
  ('logistics',          'Logistics',                 'services', 220),
  ('services',           'Services',                  'services', 230),
  ('marketing',          'Marketing',                 'services', 240),
  ('events',             'Events',                    'other',    310),
  ('other',              'Other',                     'other',    320);

create table company_partner_types (
  company_id       uuid not null references companies on delete cascade,
  partner_type_key text not null references partner_types,
  primary key (company_id, partner_type_key)
);
create index on company_partner_types (partner_type_key);

-- Carry over anything already tagged via company_categories.
insert into company_partner_types (company_id, partner_type_key)
select cc.company_id,
       case cc.category_key
         when 'ats' then 'bos' when 'consumables' then 'bos'
         when 'financing' then 'consumer_financing'
         else cc.category_key end
from company_categories cc
on conflict do nothing;

drop table company_categories;

alter table companies drop constraint companies_kind_check;
alter table companies add constraint companies_kind_check check (kind in
  ('manufacturer','distributor','wholesaler','installer','service','software',
   'logistics','financing','bank','lender','investor','insurer','event','other'));

-- One row per company with its partner types, for the admin view.
create view company_overview as
select c.id, c.name, c.kind, c.status, c.solar_related, c.country, c.priority,
       c.last_contact_on, c.hyperion_supplier_id,
       coalesce(array_agg(pt.key order by pt.sort_order)
                filter (where pt.key is not null), '{}') as partner_types,
       bool_or(pt.grp = 'financial') as is_financial_partner,
       bool_or(pt.grp = 'equipment') as is_equipment_partner
from companies c
left join company_partner_types cpt on cpt.company_id = c.id
left join partner_types pt on pt.key = cpt.partner_type_key
group by c.id;
