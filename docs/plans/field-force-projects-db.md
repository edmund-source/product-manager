# Plan: Postgres database for field-force projects

Source studied: Google Chat space **"Field Force Site Visit & Proposal
Presentation"**, about 150 messages from 21 Oct to 30 Oct 2026, read in three
pages. Older history was not read. This is a plan only. Nothing has been
migrated yet.

## 1. What the chat holds today

The space is where **telesales hands a booked lead to a field-force (FF)
officer** for the ocular (site visit). After the visit, the lead moves on to
the solar design proposal and the pitch.

| Message type | Share | Example content |
|---|---|---|
| **Endorsement** (fixed template, one per thread, assigned FF @-tagged) | ~85% | homeowner, phone, email, address, pin, appointment, source, bill, system preference, roof, payment, reservation fee, roof & shading screening, notes |
| **Attachment-only post** (bill / CRM screenshot / pin) | ~10% | image posted as its own thread right after the text, so it is not linked to the endorsement |
| **Thread replies** | few | lead asks "what system did we offer?", FF reports "roof too small, bill too small" (disqualified), lead routes client to loan officer for loan consultation, request to prioritise pre-design |
| Banter | few | ignore |

The endorsement template, as posted:

```
Homeowner / Contact No / Email Add / Location / Address / Google Pin
Appointment / Source
-- Technical & Billing Details
Monthly Bill / System Preference / Net Metering (Y/N)
Roof/Site Details (GI / Tile / Concrete / etc.) / (Age/Type)
-- Financials & Status
Mode of Payment / If Credit Card, current limit
Reservation Fee (Paid/Waived) / if waived, reason
-- [ROOF & SHADING SCREENING]
1 Shading  2 Direct Sunlight  3 Est. Roof Size  4 Purlin Type
5 Max Panels Set Expectations  6 Remarks / Special Request
Note: (free text, Taglish)
```

### Data-quality problems the design has to handle

- **Labels vary by sender**: `Homeowner` / `Home owner`, `Email Add` /
  `Email Address`, `Location / Address` / `Location/Address :` / `Address`.
  Some senders put a Hyperion lead number on its own line (`#13527622`).
- **Numbers are free text**: bills like `12k`, `6,500k`, `₱9,000`, `6-8k`,
  `130000-150000`; panel counts like `6-8`, `10plus`, `Above 10`, `He want
  personal discussion`; roof sizes like `80sq meter`, `Not Sure`, `N/A`.
  Store **min/max ranges** plus the raw text.
- **Dates have no fixed format**: `Nov11 at 2PM`, `Wednesday, November 4,
  9AM`, `Nov 10 3PM`, `Oct. 29, 2PM`, usually without a year. Parse them as
  Asia/Manila time, taking the year from when the message was posted.
- **Pins come in three forms**: decimal coordinates, degree-minute-second
  coordinates (`14°35'52.7"N`), or `maps.app.goo.gl` links. Coordinates are
  sometimes glued onto the next line (`123.701058Appointment:`).
- **Payment is multi-valued**: `Half cash, half CC BPI`, `CC RCBC / BDO /
  BPI / Metrobank`, `Installment`, `Billease or HomeCredit`, Pag-IBIG,
  existing loans.
- **Roof fields are mixed up**: material and purlin type swap between the
  two roof lines.
- **Copy-paste errors and duplicates**: the same email appears on two
  different homeowners. Two family members are endorsed for one address, a
  single property gets one endorsement per owner, and "Property 2" marks a
  second site for one customer.
- **Not all homes**: a church and a commercial building with a
  ₱130–150k/month bill. Some clients already have solar, such as a 5 kWp
  grid-tie system to upgrade to hybrid.
- **Attachments are detached**: one sender posts the image as a separate
  thread. Link it to the endorsement by sender and a time window of about 60
  seconds.

## 2. Design principles

1. **Hyperion stays the system of record.** Every project carries the
   Hyperion consultation/lead id when known. Stages use Hyperion's
   `stageKey`s and its 1-based `index1`, as given by `pipeline_reference`.
   Lost and Cancelled are status tags, not stages. This follows how this
   repo already links `companies` and `products` to Hyperion.
2. **Keep the raw message, parse into typed columns.** Every parsed row
   points back to its chat message, and the raw field values are kept in
   `jsonb`. Parser fixes can then re-run over history, and every value can be
   traced to where it came from.
3. **Imports are idempotent.** The upsert key is the Google Chat `messageId`
   or `threadId`. Re-running an import never creates duplicates, which
   matches the Gmail importer.
4. **Personal data is locked down.** The tables go in a separate schema
   `field` with RLS enabled and no policies, like
   `20261022040000_lock_down_api_access.sql`. Exports go to `data/`, which is
   git-ignored. No customer data goes in the repo or in fixtures.
5. **Proposals reuse the catalog.** Proposal line items reference
   `public.products`. Their costs can be benchmarked against
   `pricing.price_benchmarks`. This is the main reason to put the schema in
   this repo.

## 3. Schema (`field` schema)

```
staff ─┐
       ├─< projects >── customers ─< customer_contacts
sites ─┘      │
              ├─< appointments          (ocular, proposal presentation, signing, loan consult)
              ├─< site_visits           (ocular findings, 1 per completed ocular)
              ├─< proposals ─< proposal_options ─< proposal_lines >── public.products
              ├─< project_payment_prefs
              ├─< project_events        (timeline: thread replies, stage changes)
              └─< attachments
chat_messages ─< (endorsements, project_events, attachments)   provenance
```

### Reference tables
- `field.staff` — `id`, `full_name`, `email citext unique`,
  `chat_user_id unique` (the `users/1100…` id used in @-tags),
  `hyperion_uid`, `role` (`telesales`, `fieldforce`, `fieldforce_lead`,
  `loan_officer`, `solar_designer`, …, matching Hyperion role keys),
  `active`. Resolve tagged ids with `staff_directory`.
- `field.lead_sources` — `crm`, `crm_leads`, `regular_leads`, `referral`,
  `client_referral`, `bank_referral` (e.g. RCBC), `walk_in`, `other`.
- `field.banks` — BDO, BPI, RCBC, Metrobank, UnionBank, Pag-IBIG, plus
  BillEase and Home Credit. These could instead link to `public.companies`
  financing partners. Doing so is the preferred option (§7).

### Core
- `field.customers` — `id`, `full_name`, `hyperion_customer_id unique`,
  `customer_type` (`residential`, `commercial`, `institutional`,
  `church`), `is_ofw` / `on_site_representative` (the "client abroad,
  mother will assist" case), `notes`, timestamps.
- `field.customer_contacts` — `customer_id`, `kind` (`mobile`,
  `landline`, `email`), `value` (phones normalised to E.164 `+639…`),
  `label` (e.g. "better number", "representative: <name>"), `is_primary`.
  Unique on (`customer_id`, `kind`, `value`).
- `field.sites` — `id`, `customer_id`, `label` ("Property 2"),
  `address_text`, `barangay`, `city`, `province`, `region`, `landmark`
  ("near brgy hall, gray roof"), `lat numeric(9,6)`, `lng numeric(9,6)`,
  `maps_url`, `property_use`. Roof: `roof_material` (`metal_longspan`,
  `gi_sheet`, `rib_type`, `concrete`, `tile`, `wood`, `mixed`),
  `purlin_type` (`metal`, `wood`), `roof_area_sqm_est`, `shading`
  (`none`, `partial`, `heavy`), `shading_pct`, `direct_sunlight bool`.
  Existing system: `existing_system_kwp`, `existing_system_type`.
- `field.projects` — one sales opportunity for a customer at a site.
  - ids: `hyperion_consultation_id unique`, `hyperion_lead_no` (the
    `#1352…` number)
  - people: `telesales_staff_id`, `fieldforce_staff_id` (the @-tagged
    officer), `solar_designer_staff_id`, `loan_officer_staff_id`
  - funnel: `stage_key` (references `field.pipeline_stages`, seeded from
    `pipeline_reference`), `status` (`active`, `lost`, `cancelled`,
    `won`), `lost_reason` (`roof_too_small`, `bill_too_low`,
    `no_budget`, `competitor`, `unreachable`, …), `source_key`,
    `referrer_text`
  - needs: `monthly_bill_min_php`, `monthly_bill_max_php`,
    `monthly_bill_raw`, `system_preference` (`grid_tied`, `hybrid`,
    `hybrid_with_battery`, `off_grid`, `undecided`; more than one is
    allowed via an array), `net_metering bool`, `panels_expected_min`,
    `panels_expected_max`, `backup_need_note` (brownout frequency),
    `purpose` (`savings`, `backup`, `upgrade`, …), `install_urgency`
  - money: `reservation_fee_status` (`paid`, `collect_at_ocular`,
    `waived`, `unknown`), `reservation_fee_waiver_reason`,
    `credit_limit_note`
  - `remarks`, `created_at`, `updated_at`
- `field.project_payment_prefs` — `project_id`, `method` (`cash`,
  `credit_card`, `cc_installment`, `bank_loan`, `pag_ibig`, `billease`,
  `home_credit`, `in_house_installment`), `bank_id`, `share_pct`
  (`Half cash, half CC` gives 50/50), `existing_loan_note`.

### Scheduling and site visits
- `field.appointments` — `project_id`, `kind` (`ocular`,
  `proposal_presentation`, `contract_signing`, `loan_consultation`,
  `engineering_inspection`), `scheduled_at timestamptz`, `scheduled_raw`,
  `staff_id`, `status` (`scheduled`, `done`, `rescheduled`, `no_show`,
  `cancelled`), `rescheduled_from_id` (self-reference, so the reschedule
  history is kept), `notes`, `source_message_id`.
- `field.site_visits` — `appointment_id unique`, `visited_at`,
  `staff_id`. Measured values: `roof_area_sqm`, `usable_area_sqm`,
  `shading_pct`, `orientation`, `roof_condition`,
  `structural_retrofit_needed`, `main_panel_amps`, `service_phase`.
  Also `max_panels_fit`, `recommended_kwp`, `recommended_system`,
  `outcome` (`qualified`, `disqualified`, `needs_followup`),
  `disqualify_reason`, `reservation_fee_collected`, `notes`.

### Proposals and presentations
- `field.proposals` — `project_id`, `version int` (unique per project),
  `prepared_by_staff_id` (solar designer), `prepared_at`,
  `presented_appointment_id`, `status` (`draft`, `presented`,
  `accepted`, `declined`, `superseded`), `decision_at`,
  `decline_reason`, `document_url`.
- `field.proposal_options` — `proposal_id`, `label` ("Grid 5 kWp",
  "Hybrid 6 kWp + 10 kWh"), `system_type`, `kwp`, `battery_kwh`,
  `panel_count`, `est_monthly_savings_php`, `est_payback_years`,
  `price_php`, `discount_php`, `promo_code`, `is_chosen`.
- `field.proposal_lines` — `option_id`, `product_id → public.products`
  (null for labour or other free-text lines), `description`, `qty`,
  `unit_price_php`, `unit_cost_php` (filled from `pricing` so margin can
  be reported).

### Provenance and timeline
- `field.chat_messages` — `message_id pk`, `thread_id`, `space_id`,
  `sender_staff_id`, `sender_email`, `created_at`, `body`, `raw jsonb`,
  `kind` (`endorsement`, `reply`, `attachment_only`, `chatter`),
  `parsed_at`, `parse_warnings text[]`.
- `field.endorsements` — `message_id unique → chat_messages`,
  `project_id`, `fields jsonb` (label → raw value, exactly as posted),
  `parser_version`. Re-parsing upserts this table, then updates the typed
  columns.
- `field.project_events` — `project_id`, `occurred_at`, `actor_staff_id`,
  `kind` (`endorsed`, `ff_reply`, `lead_followup`, `stage_changed`,
  `loan_referral`, `prioritised`, `note`), `body`, `source_message_id`.
- `field.attachments` — `project_id`, `message_id`,
  `chat_attachment_id unique`, `filename`, `mime_type`, `kind`
  (`electric_bill`, `crm_screenshot`, `roof_photo`, `location`,
  `roof_plan`, `proposal_pdf`, `other`), `storage_path` (Supabase
  Storage, private bucket).

### Views
- `field.ocular_calendar`: upcoming oculars per FF officer, by day.
- `field.endorsement_quality`: the share of required fields filled in, per
  telesales sender. Use it for coaching.
- `field.funnel`: projects by `stage_key` × source × FF officer, with
  conversion from endorsed to visited, presented, and signed.
- `field.proposal_margins`: proposal lines joined to
  `pricing.price_benchmarks`.
- `field.possible_duplicates`: the same phone, email, or rounded lat/lng
  on different customers.

## 4. Ingestion

1. **Sweep skill**: `.claude/skills/fieldforce-sweep/SKILL.md`, modelled on
   `supplier-sweep`. It reads the space with the Google Chat connector (50
   messages per page, with an optional `since` date) and writes
   `data/fieldforce_chat.json`, which is git-ignored.
2. **Importer**: `pnpm import:chat data/fieldforce_chat.json`
   (`scripts/import-chat-fieldforce.mjs`). It runs these steps:
   - upsert `chat_messages` and classify each one (the template marker
     `Homeowner` / `Home owner` together with `Monthly Bill` means an
     endorsement)
   - parse with a label-alias map, and store the raw fields in
     `endorsements.fields`
   - normalise bills, panel counts and roof area into min/max, dates into
     Asia/Manila time, pins from all three forms, phones into E.164, and
     payment strings into `project_payment_prefs` rows
   - match or create a customer (Hyperion lead number first, then phone, then
     email plus name). An email shared by two different names raises a
     warning rather than a merge.
   - create the project, the ocular appointment, the `endorsed` event, and
     the FF assignment from the first @-tag
   - add thread replies as `project_events` on the project for that
     thread
   - attach detached attachment-only posts (same sender, posted within
     about 60 seconds)
3. **Hyperion enrichment** (optional, read-only): fill
   `hyperion_consultation_id`, `stage_key`, and status from
   `ff_schedule`, `sd_pipeline` and `customer_search`. Hyperion wins on
   stage and status.
4. **Parser tests**: anonymised samples of every label variant in
   `scripts/fixtures/`, with no real names, phones or emails.

## 5. Delivery steps

1. `20261030000000_field_schema.sql`: the schema, reference tables, and
   pipeline stage seed.
2. `20261030010000_field_core.sql`: customers, sites, projects,
   appointments, site visits, and payment prefs.
3. `20261030020000_field_proposals.sql`: proposals, options and lines,
   with a foreign key to `public.products`.
4. `20261030030000_field_provenance.sql`: chat messages, endorsements,
   events, attachments, and the views.
5. `20261030040000_field_lock_down.sql`: RLS on every `field.*` table and
   `security_invoker` on the views.
6. Parser with fixtures, then the importer, then the sweep skill. Run a
   backfill over the full space history.
7. README section, and add `field` to the Supabase exposed schemas only if
   an app needs it.

## 6. Process improvement (optional but cheap)

The parsing problems above come from free-text chat posts. A Google Form, or
a Chat app card with dropdowns for preference, roof, payment and bank, plus
date and number pickers, posting into the same space would remove most of
the cleanup. It would also let the endorsement go straight into the
database.

## 7. Open questions

1. **Scope vs Hyperion.** Hyperion already has customers, the ocular
   schedule and the SD pipeline. Is this database an analytics copy that
   adds what only the chat holds (screening answers, notes, FF outcomes),
   or should it become the working store for proposals? The plan assumes
   the first and treats proposals as new data.
2. **Same repo or new?** This repo is about products and pricing. Proposals
   tie in through `public.products`, but customer personal data may belong
   in a separate repo and database with stricter access.
3. **Where do proposal and presentation details live today?** They are not
   in this chat. They may be in Drive (proposal PDFs, design sheets) or in
   Hyperion's SD stage. Point me at them and the `proposals` tables can be
   filled too.
4. **Banks and financing partners.** Should they reuse
   `public.companies` with partner type `financing`? This plan recommends
   yes.
5. **Retention.** How long should raw chat bodies with phones and emails be
   kept once they have been parsed?
