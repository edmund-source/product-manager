-- Row level security on every table, with no policies: Supabase's anon and
-- authenticated API roles see nothing, while this project's scripts (which
-- connect as the database owner) are unaffected. Views run with the caller's
-- rights so they can't be used to read around it. Safe to re-run.

alter table companies              enable row level security;
alter table company_locations      enable row level security;
alter table contacts               enable row level security;
alter table brands                 enable row level security;
alter table company_brands         enable row level security;
alter table products               enable row level security;
alter table product_hyperion_skus  enable row level security;
alter table interactions           enable row level security;
alter table documents              enable row level security;
alter table product_categories     enable row level security;
alter table partner_types          enable row level security;
alter table company_partner_types  enable row level security;
alter table product_equipment      enable row level security;
alter table product_financing      enable row level security;
alter table product_insurance      enable row level security;
alter table partner_products       enable row level security;
alter table financing_terms        enable row level security;
alter table schema_migrations      enable row level security;
alter table pricing.source_types     enable row level security;
alter table pricing.price_lists      enable row level security;
alter table pricing.equipment_prices enable row level security;
alter table pricing.fx_rates         enable row level security;

alter view company_overview           set (security_invoker = true);
alter view partner_catalog            set (security_invoker = true);
alter view pricing.normalized_prices  set (security_invoker = true);
alter view pricing.latest_prices      set (security_invoker = true);
alter view pricing.price_benchmarks   set (security_invoker = true);
alter view pricing.unmatched_prices   set (security_invoker = true);
