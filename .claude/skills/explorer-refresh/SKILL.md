---
name: explorer-refresh
description: Weekly incremental refresh of the Helios partner explorer artifact - sweep only the Gmail since the last update, fold it into the stored extract, re-check stages that changed, rebuild and republish the page. Use when the weekly routine fires, when someone clicks Refresh now on the explorer, or when asked to refresh / update the partner explorer.
---

# Partner explorer refresh

The explorer is the claude.ai artifact
**https://claude.ai/artifact/LuE9H7FkBDayBpqCFth7zw**. Its data lives in the
artifact itself as published files under `state/` (contact emails and phone
numbers stripped), so a fresh session can restore it. Each refresh reads only
mail newer than the last update. Gmail and Drive are read-only: never send,
label, archive, trash or modify anything. `data/` is git-ignored: never commit
it.

## 1. Restore the state

1. Work in this repo on branch `claude/awesome-curie-c9ea4d` (or `main` once
   merged); `mkdir -p data`.
2. `Artifact` `action: "read"` on the URL above (required before republishing),
   then `action: "read"` with `paths`: `state/manifest.json`,
   `state/suppliers_from_gmail.json`, `state/attachment_prices.json`,
   `state/coo_pricelists.json`, `state/stage_evidence.json`,
   `state/fin_summary.json`. Keep the default `out_dir` (saving elsewhere asks
   the person) and copy each saved file into `data/` under the same name.
3. From `data/manifest.json`: `last_sweep` (YYYY-MM-DD), `trigger_id`,
   `schedule`, `coo_folder_id`, `coo_quotes_modified`. The sweep window starts
   two days before `last_sweep` (overlap is safe: the merge de-duplicates).
   Gmail's `after:` takes `YYYY/MM/DD`.

## 2. Sweep only the new mail (two subagents, in parallel, model `sonnet`)

- **Bodies:** give a `general-purpose` subagent the brief in
  `.claude/skills/supplier-sweep/SKILL.md` §2 with these changes: add
  `after:<window start>` to every query; open only threads with a message in
  the window; output `data/delta_suppliers.json` in the same schema, one object
  per company that has new mail, with every field as it stands now (status,
  summary, next step, last contact) and only the new products, contacts,
  thread ids and attachments. An empty array is a valid result.
- **Attachments:** a second subagent with the §2b brief, also limited to
  `after:<window start>`, writing `data/delta_attachments.json` (same
  per-file schema as `attachment_prices.json`), using
  `python3 -I scripts/extract-gmail-attachments.py`.

## 3. Check the COO's price-list folder

Search Drive for `parentId = '<coo_folder_id>'`. If `supplier_quotes.csv` or
`suppliers.csv` has a `modifiedTime` later than `coo_quotes_modified`,
download both (`download_file_content`; the CSV comes back base64, saved to a
file when large), decode them into `data/`, and run
`python3 -I scripts/convert-supplier-quotes.py data/supplier_quotes.csv data/suppliers.csv data/coo_pricelists.json`.
Record the new `modifiedTime` in the manifest. Otherwise keep the stored
`coo_pricelists.json`.

## 3b. Business cards saved on the page

Edmund saves business cards through Marie into the artifact's private `cards`
collection (contact details live only there, never in the page or `state/`).
Load `ArtifactData` (ToolSearch) and `list` (or `query`) collection `cards` on
the artifact URL; write the documents to `data/cards.json` (an array; plain
objects or `{id, data}`), then

```bash
node scripts/cards-to-suppliers.mjs data/cards.json data/delta_cards.json
```

New companies come in as `potential_partner`; a card that Marie matched to a
company already in the list (`matched_company`) only adds its people, brands
and partner types. Keep the list of card ids for step 6.

## 4. Merge

```bash
node scripts/merge-incremental.mjs suppliers data/suppliers_from_gmail.json data/delta_suppliers.json data/suppliers_from_gmail.json
node scripts/merge-incremental.mjs suppliers data/suppliers_from_gmail.json data/delta_cards.json data/suppliers_from_gmail.json
node scripts/merge-incremental.mjs files data/attachment_prices.json data/delta_attachments.json data/attachment_prices.json
jq -s 'add' data/attachment_prices.json data/coo_pricelists.json > data/all_price_files.json
node scripts/merge-attachment-prices.mjs data/suppliers_from_gmail.json data/all_price_files.json data/suppliers_merged.json
```

## 5. Re-check stages that may have moved (one `sonnet` subagent, only if needed)

List the companies in `delta_suppliers.json` that carry a financing partner
type (consumer_financing, business_financing, investment, insurance,
payments). If there are any, give one subagent the stage-evidence brief:
for each, open its threads, find the most decisive email for its recorded
stage, list contract-type files, judge `confirmed | inferred |
not_supported`, give `suggested_status` when the emails clearly show another
stage, and a one-sentence `basis`. Output `data/delta_evidence.json` with
objects `{company, status, verdict, suggested_status, basis, evidence:
[{thread_id, date, from_domain, subject, shows}], contract_files: [{filename,
thread_id}]}`; then
`node scripts/merge-incremental.mjs evidence data/stage_evidence.json data/delta_evidence.json data/stage_evidence.json`.
If a financing partner's stage or terms changed, update the matching
headline in `data/fin_summary.json` (one or two sentences, facts from the
emails only).

## 6. Rebuild and republish

```bash
python3 -I scripts/explorer/build.py data/suppliers_merged.json data/all_price_files.json data/partner-explorer.html \
  --date <today> --evidence data/stage_evidence.json --fin-summary data/fin_summary.json \
  --trigger <trigger_id> --schedule "<schedule>"
# stored copies without contact details (writes data/state_*.json)
python3 -I scripts/explorer/scrub-state.py data
```

Set `last_sweep` to today in `data/manifest.json`. Then `Artifact` publish
with `file_path: data/partner-explorer.html`, the `url` above, no `icon`, no
`capabilities` (the stored declaration carries the Refresh button's
connector), and `files`:
`state/manifest.json` → `data/manifest.json`,
`state/suppliers_from_gmail.json` → `data/state_suppliers.json`,
`state/attachment_prices.json` → `data/state_attachments.json`,
`state/coo_pricelists.json` → `data/coo_pricelists.json`,
`state/stage_evidence.json` → `data/state_evidence.json`,
`state/fin_summary.json` → `data/fin_summary.json`.

After the publish succeeds, mark each loaded card with one `ArtifactData`
`batch` of `update`s on `cards/<id>`: `{loaded: true, loaded_on: <today>}`.
If `DATABASE_URL` points at the live database in this session, also run
`pnpm import:gmail data/suppliers_merged.json` so the cards reach Supabase;
otherwise say in the report that they are in the explorer only.

## 7. Report

One short summary: the window swept, cards loaded, new companies, companies with new mail,
new priced lines, stage changes or new suggestions, files that could not be
read. If nothing new arrived, still republish (the "Updated" date moves) and
say so.
