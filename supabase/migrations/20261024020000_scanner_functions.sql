-- Database side of the weekly supplier inbox scanner, as functions, so the
-- scanner can write with one call each through the Supabase connector (cloud
-- sessions cannot open direct Postgres connections). Each takes and returns
-- jsonb. Extracted prices only ever land in offer_candidates as 'pending'.
-- Called by .claude/skills/supplier-inbox-scan and scripts/scanner/db.mjs.

create or replace function scanner_norm_domain(p text) returns text language sql immutable as $$
  select nullif(regexp_replace(regexp_replace(regexp_replace(lower(trim(coalesce(p, ''))), '^https?://', ''), '^www\.', ''), '/.*$', ''), '')
$$;

create or replace function scanner_run_start(p_phase text) returns jsonb language plpgsql as $$
declare v_last jsonb; v_run jsonb;
begin
  if p_phase not in ('classify', 'extract') then raise exception 'phase must be classify or extract'; end if;
  select to_jsonb(r) into v_last from (select id, started_at, finished_at, summary from scanner_runs
    where phase = p_phase and finished_at is not null order by started_at desc limit 1) r;
  insert into scanner_runs (phase) values (p_phase) returning jsonb_build_object('id', id, 'started_at', started_at) into v_run;
  return jsonb_build_object('run', v_run, 'last_finished', v_last);
end $$;

create or replace function scanner_run_finish(p_id uuid, p_summary jsonb) returns jsonb language sql as $$
  update scanner_runs set finished_at = now(), summary = coalesce(p_summary, '{}'::jsonb) where id = p_id
  returning jsonb_build_object('finished', id)
$$;

create or replace function scanner_last(p_phase text) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'last_finished', (select to_jsonb(r) from (select id, started_at, finished_at, summary from scanner_runs
      where phase = p_phase and finished_at is not null order by started_at desc limit 1) r),
    'pending_candidates', (select count(*) from offer_candidates where status = 'pending'))
$$;

create or replace function scanner_companies() returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('id', c.id, 'name', c.name, 'domain', c.website_domain::text, 'status', c.status, 'kind', c.kind,
      'drive_folder_id', c.drive_folder_id,
      'emails', coalesce((select jsonb_agg(distinct lower(ct.email::text)) from contacts ct where ct.company_id = c.id and ct.email is not null), '[]'::jsonb),
      'partner_types', coalesce((select jsonb_agg(pt.partner_type_key) from company_partner_types pt where pt.company_id = c.id), '[]'::jsonb)) x
    from companies c) s
$$;

-- p: [{company_id?, name, website_domain, country, kind, status, partner_types[], introduced_by, summary,
--      first_contact_on, last_contact_on, drive_folder_id, contacts[{full_name,title,email,phone}],
--      emails[{gmail_thread_id, occurred_on, direction, subject, summary}]}]
create or replace function scanner_classify(p jsonb) returns jsonb language plpgsql as $$
declare r jsonb; c jsonb; m jsonb; v_id uuid; v_dom text; v_created boolean; v_out jsonb := '[]'::jsonb;
  free_mail constant text[] := array['gmail.com','yahoo.com','outlook.com','hotmail.com','qq.com','163.com','126.com','icloud.com'];
begin
  for r in select * from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    v_dom := scanner_norm_domain(r->>'website_domain');
    if v_dom = any(free_mail) then v_dom := null; end if;
    v_id := nullif(r->>'company_id', '')::uuid;
    if v_id is null and v_dom is not null then select id into v_id from companies where website_domain = v_dom; end if;
    if v_id is null then select id into v_id from companies where lower(name) = lower(r->>'name') limit 1; end if;
    v_created := v_id is null;
    if v_created then
      insert into companies (name, website_domain, country, kind, status, introduced_by, summary, first_contact_on, last_contact_on, drive_folder_id)
      values (r->>'name', v_dom, r->>'country',
        case when r->>'kind' in ('manufacturer','distributor','wholesaler','installer','service','software','logistics','financing','bank','lender','investor','insurer','event','other') then r->>'kind' else 'other' end,
        case when r->>'status' in ('cold_inbound','intro','in_discussion','quoted','meeting_held','accredited','active_supplier','declined','dormant','unknown') then r->>'status' else 'cold_inbound' end,
        r->>'introduced_by', r->>'summary', (r->>'first_contact_on')::date, (r->>'last_contact_on')::date, nullif(r->>'drive_folder_id', ''))
      returning id into v_id;
    else
      -- never lower a stage or overwrite a summary; fill gaps and move dates forward
      update companies set
        website_domain = coalesce(website_domain, v_dom),
        country = coalesce(country, r->>'country'),
        drive_folder_id = coalesce(drive_folder_id, nullif(r->>'drive_folder_id', '')),
        summary = coalesce(summary, r->>'summary'),
        first_contact_on = least(coalesce(first_contact_on, (r->>'first_contact_on')::date), coalesce((r->>'first_contact_on')::date, first_contact_on)),
        last_contact_on = greatest(coalesce(last_contact_on, (r->>'last_contact_on')::date), coalesce((r->>'last_contact_on')::date, last_contact_on)),
        updated_at = now()
      where id = v_id;
    end if;
    insert into company_partner_types (company_id, partner_type_key)
      select v_id, t.key from partner_types t where t.key in (select jsonb_array_elements_text(coalesce(r->'partner_types', '[]'::jsonb)))
      on conflict do nothing;
    for c in select * from jsonb_array_elements(coalesce(r->'contacts', '[]'::jsonb)) loop
      if nullif(c->>'email', '') is not null then
        insert into contacts (company_id, full_name, title, email, phone) values (v_id, c->>'full_name', c->>'title', lower(c->>'email'), c->>'phone')
        on conflict (company_id, email) do update set full_name = coalesce(contacts.full_name, excluded.full_name),
          title = coalesce(excluded.title, contacts.title), phone = coalesce(contacts.phone, excluded.phone), updated_at = now();
      elsif nullif(c->>'full_name', '') is not null
        and not exists (select 1 from contacts where company_id = v_id and lower(full_name) = lower(c->>'full_name')) then
        insert into contacts (company_id, full_name, title, phone) values (v_id, c->>'full_name', c->>'title', c->>'phone');
      end if;
    end loop;
    for m in select * from jsonb_array_elements(coalesce(r->'emails', '[]'::jsonb)) loop
      continue when nullif(m->>'gmail_thread_id', '') is null;
      insert into interactions (company_id, occurred_on, channel, direction, subject, summary, gmail_thread_id)
      values (v_id, (m->>'occurred_on')::date, 'email', case when m->>'direction' = 'outbound' then 'outbound' else 'inbound' end,
        m->>'subject', m->>'summary', m->>'gmail_thread_id')
      on conflict (company_id, gmail_thread_id) do update set occurred_on = greatest(interactions.occurred_on, excluded.occurred_on),
        subject = excluded.subject, summary = coalesce(excluded.summary, interactions.summary);
    end loop;
    v_out := v_out || jsonb_build_object('name', r->>'name', 'id', v_id, 'created', v_created);
  end loop;
  return jsonb_build_object('companies', v_out);
end $$;

-- p: [{company_id, drive_file_id, filename, kind, gmail_thread_id, received_on, extraction_notes,
--      lines[{brand_name, category_key, model_code, raw_product_name, specs, price, currency, price_basis,
--             vat_included, moq, valid_until, observed_on, confidence, extraction_notes}]}]
create or replace function scanner_extract(p jsonb) returns jsonb language plpgsql as $$
declare d jsonb; l jsonb; v_doc uuid; n int; v_out jsonb := '[]'::jsonb;
begin
  for d in select * from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    insert into documents (company_id, kind, filename, storage_path, gmail_thread_id, received_on, drive_file_id, extracted_at, extraction_notes)
    values ((d->>'company_id')::uuid,
      case when d->>'kind' in ('price_list','brochure','company_profile','datasheet','certificate','contract','other') then d->>'kind' else 'other' end,
      d->>'filename', 'drive:' || (d->>'drive_file_id'), d->>'gmail_thread_id', (d->>'received_on')::date, d->>'drive_file_id', now(), d->>'extraction_notes')
    on conflict (drive_file_id) do update set kind = excluded.kind, extracted_at = now(), extraction_notes = excluded.extraction_notes
    returning id into v_doc;
    -- a re-read file replaces its own pending candidates; reviewed ones stay
    delete from offer_candidates where document_id = v_doc and status = 'pending';
    n := 0;
    for l in select * from jsonb_array_elements(coalesce(d->'lines', '[]'::jsonb)) loop
      continue when nullif(l->>'raw_product_name', '') is null;
      insert into offer_candidates (company_id, document_id, brand_name, category_key, model_code, raw_product_name, specs, price, currency,
        price_basis, vat_included, moq, valid_until, observed_on, confidence, extraction_notes)
      values ((d->>'company_id')::uuid, v_doc, l->>'brand_name',
        (select key from product_categories where key = l->>'category_key'), l->>'model_code', left(l->>'raw_product_name', 500),
        case when jsonb_typeof(l->'specs') = 'object' then l->'specs' else '{}'::jsonb end,
        case when (l->>'price') ~ '^-?[0-9]+(\.[0-9]+)?$' then (l->>'price')::numeric end,
        case when (l->>'currency') ~ '^[A-Za-z]{3}$' then upper(l->>'currency') end,
        case when l->>'price_basis' in ('exw','fob','cif','ddp','delivered','retail','wholesale') then l->>'price_basis' else 'unknown' end,
        case when jsonb_typeof(l->'vat_included') = 'boolean' then (l->>'vat_included')::boolean end,
        case when (l->>'moq') ~ '^[0-9]+$' then (l->>'moq')::int end,
        case when (l->>'valid_until') ~ '^\d{4}-\d{2}-\d{2}' then left(l->>'valid_until', 10)::date end,
        coalesce(case when (l->>'observed_on') ~ '^\d{4}-\d{2}-\d{2}' then left(l->>'observed_on', 10)::date end, (d->>'received_on')::date),
        case when l->>'confidence' in ('high','medium','low') then l->>'confidence' else 'medium' end,
        l->>'extraction_notes');
      n := n + 1;
    end loop;
    v_out := v_out || jsonb_build_object('filename', d->>'filename', 'document_id', v_doc, 'candidates', n);
  end loop;
  return jsonb_build_object('documents', v_out);
end $$;

-- Sinosure / trade-credit mentions found in supplier emails.
-- p: [{company_id, policy_status?, limit_status?, limit_amount_usd?, payment_terms_days?, premium_rate_pct?,
--      asked_on?, next_follow_up_on?, note, gmail_thread_id?, email_date?}]
-- Stages only move forward (asked over not_asked; has_policy/no_policy/declined over asked).
create or replace function scanner_trade_credit(p jsonb) returns jsonb language plpgsql as $$
declare r jsonb; v_out jsonb := '[]'::jsonb; v_old record;
  pol constant text[] := array['not_asked','asked','has_policy','no_policy','declined'];
  lim constant text[] := array['none','requested','approved','rejected','expired'];
begin
  for r in select * from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    insert into supplier_trade_credit (company_id) values ((r->>'company_id')::uuid) on conflict (company_id) do nothing;
    select * into v_old from supplier_trade_credit where company_id = (r->>'company_id')::uuid;
    update supplier_trade_credit set
      policy_status = case when r->>'policy_status' = any(pol)
          and array_position(pol, r->>'policy_status') > array_position(pol, policy_status) then r->>'policy_status' else policy_status end,
      limit_status = case when r->>'limit_status' = any(lim) and r->>'limit_status' <> 'none' then r->>'limit_status' else limit_status end,
      limit_amount_usd = coalesce(case when (r->>'limit_amount_usd') ~ '^[0-9]+(\.[0-9]+)?$' then (r->>'limit_amount_usd')::numeric end, limit_amount_usd),
      payment_terms_days = coalesce(case when (r->>'payment_terms_days') ~ '^[0-9]+$' then (r->>'payment_terms_days')::smallint end, payment_terms_days),
      premium_rate_pct = coalesce(case when (r->>'premium_rate_pct') ~ '^[0-9]+(\.[0-9]+)?$' then (r->>'premium_rate_pct')::numeric end, premium_rate_pct),
      asked_on = coalesce(asked_on, case when (r->>'asked_on') ~ '^\d{4}-\d{2}-\d{2}' then left(r->>'asked_on', 10)::date end),
      next_follow_up_on = coalesce(case when (r->>'next_follow_up_on') ~ '^\d{4}-\d{2}-\d{2}' then left(r->>'next_follow_up_on', 10)::date end, next_follow_up_on),
      notes = concat_ws(E'\n', notes, nullif(concat_ws(' ', '[' || coalesce(r->>'email_date', current_date::text) || ' email]', r->>'note',
        case when nullif(r->>'gmail_thread_id', '') is not null then '(thread ' || (r->>'gmail_thread_id') || ')' end), ''))
    where company_id = (r->>'company_id')::uuid;
    v_out := v_out || jsonb_build_object('company_id', r->>'company_id', 'policy_before', v_old.policy_status);
  end loop;
  return jsonb_build_object('updated', v_out);
end $$;

revoke all on function scanner_norm_domain(text), scanner_run_start(text), scanner_run_finish(uuid, jsonb), scanner_last(text),
  scanner_companies(), scanner_classify(jsonb), scanner_extract(jsonb), scanner_trade_credit(jsonb) from public, anon, authenticated;
