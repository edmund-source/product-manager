-- Keep the register private on Supabase: tables in public are exposed through
-- the auto-generated API, so enable RLS with no policies (anon/authenticated
-- get nothing; the postgres role and service key still have full access).
-- Views run as the caller so they cannot be used to read around RLS.

alter table companies enable row level security;
alter table company_locations enable row level security;
alter table contacts enable row level security;
alter table brands enable row level security;
alter table company_brands enable row level security;
alter table products enable row level security;
alter table product_hyperion_skus enable row level security;
alter table offers enable row level security;
alter table interactions enable row level security;
alter table documents enable row level security;
alter table product_categories enable row level security;
alter table partner_types enable row level security;
alter table company_partner_types enable row level security;
alter table schema_migrations enable row level security;

alter view latest_offers set (security_invoker = true);
alter view company_overview set (security_invoker = true);
