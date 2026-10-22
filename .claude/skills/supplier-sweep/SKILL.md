---
name: supplier-sweep
description: Search Edmund's Gmail for every company selling or pitching to Helios (equipment suppliers, financial partners, other vendors), write data/suppliers_from_gmail.json and load it into the database. Use when asked to run, refresh or redo the supplier / partner sweep. Optional argument: a start date (YYYY/MM/DD) to only sweep newer mail.
---

# Supplier & partner sweep

Builds the vendor/partner register from Edmund's mailbox (edmund@joinhelios.com)
and loads it with `pnpm import:gmail`. Gmail is **read-only** here: never send,
label, archive, trash or modify anything.

Argument: optional `after` date `YYYY/MM/DD`. If given, add `after:<date>` to
every query and merge the results into the existing
`data/suppliers_from_gmail.json` instead of replacing it.

## 1. Database ready

Skip if `pnpm db:migrate` already works against `.env`. Otherwise:

```bash
# local Postgres (container): start it, then create role + db once
pg_ctlcluster 16 main start || service postgresql start
su postgres -c "psql -c \"create role pm login password 'pm'\"" || true
su postgres -c "createdb -O pm product_manager" || true
su postgres -c "psql -d product_manager -c 'create extension if not exists pgcrypto; create extension if not exists citext;'"
echo 'DATABASE_URL=postgresql://pm:pm@localhost:5432/product_manager' > .env
pnpm install && set -a && . ./.env && set +a && pnpm db:migrate
```

## 2. Sweep (delegate to one subagent)

The search takes ~20 minutes and a lot of context, so give it to a single
`general-purpose` subagent with the brief below, run in the background, and
wait for its report. Don't run the searches yourself as well.

> **Goal.** Build a register of every company that sells, or is trying to
> sell, to Helios (residential solar, Philippines) from Edmund's Gmail, using
> the `mcp__Gmail__search_threads` and `mcp__Gmail__get_thread` tools (load via
> ToolSearch). Read-only.
>
> **In scope**
> - Equipment: inverters, panels, batteries, mounting, BOS, EV chargers,
>   appliances; manufacturers, distributors, wholesalers, installers.
> - Financial partners: banks/lenders financing Helios customers (solar loans,
>   consumer finance, installments, BNPL), lenders/debt to Helios (credit
>   lines, working capital, trade/receivables finance, venture debt), equity
>   investors/funds in real discussion, insurers, payment partners.
> - Other vendors pitching Helios: software/SaaS, logistics, marketing/SEO,
>   services, events (event organisers = low priority).
>
> **Out of scope:** Helios staff (`@joinhelios.com`) — but record the vendor
> they forward or introduce; transactional bank/wallet notices (BPI BizLink
> "Pay non-BPI Accounts", Maya advisories) unless that bank also has real
> partnership threads; newsletters/courses with no pitch; customers.
>
> **Queries** (pageSize 50; paginate while new companies keep appearing;
> results that overflow are saved to a file — extract date/sender/subject/id
> with `jq`):
> - `inverter`; `battery OR LiFePO4 OR BESS OR "energy storage"`;
>   `"solar panel" OR "PV module" OR "tier 1"`
> - `distributor OR supplier OR manufacturer OR factory OR OEM OR wholesale OR MOQ OR FOB OR EXW OR CIF`
> - `"price list" OR pricelist OR catalog OR catalogue OR brochure OR "company profile" OR datasheet`
> - `quotation OR quote OR "EV charger" OR mounting OR racking OR cable OR dealer OR microinverter OR hybrid`
> - brands: Deye, Growatt, Huawei, SMA, Sungrow, Solis, GoodWe, APsystems,
>   Enphase, Atmoce, Hoymiles, Jinko, LONGi, Trina, "JA Solar",
>   "Canadian Solar", "AE Solar", Pylontech, BYD, Dyness, Felicity, Must,
>   SRNE, Luxpower, Livoltek, Sigenergy, "Fox ESS", Voltronic, Sunsynk,
>   SolarEdge, EcoFlow, Hopetrek, Solgenysis, TechnoForce
> - `"Made-in-China" OR alibaba`; `subject:(partnership OR introduction OR proposal)`
> - `logistics OR insurance OR SEO OR CRM OR demo`
> - financing: `financing OR loan OR "solar loan" OR lender OR lending OR credit OR "credit line" OR "working capital" OR debt OR "trade finance" OR receivables OR factoring OR "venture debt"`
> - investors: `investor OR investment OR "term sheet" OR fund OR "Series A"`
> - partners by name: "Home Credit", BPI, RCBC, BDO, UnionBank, Pag-IBIG,
>   "Security Bank", PNB, Metrobank, Helicap, Lendable, Aquila, 100x100, DCG,
>   Maya, GCash, Billease, Atome, Tendo, "First Circle", Esquire, Cashalo,
>   PayMongo, ATRAM, Mynt
> - `in:sent` versions of the supplier and financing queries (Edmund's replies)
> - finally, a sweep by sender domain for every vendor domain found, to catch
>   their other threads.
>
> Open a thread (`get_thread`, `messageFormat: PLAIN_TEXT`) only when needed
> to pin down company, products, prices/terms, contacts or location. Prices
> inside attachments (PDF/JPG/XLSX) can't be read — leave them null and list
> the filename.
>
> **Output:** write `data/suppliers_from_gmail.json` (create `data/`), a JSON
> array, one object per company (merge all threads of the same company,
> matched by email domain):
>
> ```json
> {
>   "company": "...", "website_domain": "...", "country": "...",
>   "ph_presence": "city/province of a PH office or warehouse, else null",
>   "kind": "manufacturer|distributor|wholesaler|installer|service|software|logistics|financing|bank|lender|investor|insurer|event|other",
>   "solar_related": true,
>   "partner_types": ["one or more of: inverters, panels, batteries, mounting, bos, equipment, ev_charging, appliances, consumer_financing, business_financing, investment, insurance, payments, software, logistics, services, marketing, events, other"],
>   "brands": ["brands they make or carry"],
>   "products": [{"name": "...", "model": "...", "category": "...", "price": null, "currency": "PHP|USD|CNY|null", "price_basis": "exw|fob|cif|ddp|delivered|retail|wholesale|null", "notes": "specs; for financing: rate, tenor, fees, terms"}],
>   "contacts": [{"name": "...", "title": "...", "email": "...", "phone": "only if in a business signature"}],
>   "introduced_by": "person/org or null",
>   "status": "cold_inbound|intro|in_discussion|quoted|meeting_held|accredited|active_supplier|declined|dormant|unknown",
>   "first_contact": "YYYY-MM-DD", "last_contact": "YYYY-MM-DD",
>   "thread_ids": ["..."], "has_attachments": ["filename.pdf"],
>   "summary": "1-2 sentences: what they offer and where it stands"
> }
> ```
>
> Only record facts visible in the emails; use null when unknown — never guess
> prices or contacts. Financial partners list financing products in
> `products` (price null, terms in notes).
>
> **Final reply (under 400 words):** number of companies; counts by kind,
> by partner type, and solar / non-solar; the queries run; what couldn't be
> read; the top ~12 equipment suppliers and the financial partners with real
> threads, one line each. Don't paste the JSON.

## 3. Check and load

```bash
jq 'length' data/suppliers_from_gmail.json
jq -r '.[] | select((.partner_types // []) | length == 0) | .company' data/suppliers_from_gmail.json  # should be empty
set -a && . ./.env && set +a && pnpm import:gmail data/suppliers_from_gmail.json
psql "$DATABASE_URL" -c "select count(*) companies,
  count(*) filter (where is_financial_partner) financial,
  count(*) filter (where is_equipment_partner) equipment from company_overview"
```

The importer prints `skipped <company>: <error>` for any row it couldn't load;
fix those (usually an unexpected enum value) and re-run — it is idempotent.

## 4. Report to Edmund

Summarise the subagent's counts, the database totals, the top equipment
suppliers (with prices/terms where known) and financial partners by stage, and
the gaps (unreadable attachments, keyword search not a full read). `data/` is
git-ignored: never commit the extract, it contains contact details.
