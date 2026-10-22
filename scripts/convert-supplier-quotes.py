#!/usr/bin/env python3
"""Converts the COO's compiled supplier price lists (supplier_quotes.csv and
suppliers.csv from the "Supplier price lists" Drive folder) into the
per-file format of data/attachment_prices.json, so `pnpm merge:attachments`
and `pnpm import:gmail` load them as partner price lists next to the Gmail
sweep. Every tier on a list is kept as its own line, named "(Installer)",
"(SRP)" and so on; suppliers.csv decides VAT and which tier is the default.

  python3 -I scripts/convert-supplier-quotes.py supplier_quotes.csv suppliers.csv data/coo_pricelists.json
"""
import csv
import json
import sys

quotes_file, suppliers_file, out_file = sys.argv[1:4]

# The sheet's supplier names, mapped to the register's name and domain so the
# merge attaches prices to the existing company instead of adding a duplicate.
REGISTER = {
    'Ecosolutions': ('EcoSolutions (RAR Ventures Inc.)', 'ecosolutions.ph', None, None),
    'IAN Solar': ('IAN Solar Energy Inc.', None, None, None),
    'Photonergy': ('Photonergy Inc.', None, None, None),
    'Zhejiang Gankong Electric': ('Zhejiang Gankong Electric', None, 'manufacturer', 'China'),
    'Power Ai Philippines': ('Power Ai Philippines', None, 'distributor', 'Philippines'),
    'FIREFLY Solar (FELCO)': ('FIREFLY Solar (FELCO)', None, 'distributor', 'Philippines'),
    'Goodwell': ('Goodwell Energy Phil Tech Corporation', None, 'distributor', 'Philippines'),
}
CATEGORY = {'Inverter': 'inverters', 'Solar Panel': 'panels', 'Battery': 'batteries', 'Mounting': 'mounting',
            'EV Charger': 'ev_charging',
            # kits, portable stations and tools stay out of the electrical and per-kW comparisons
            'Energy Storage System': 'other', 'Portable Power Station': 'other', 'Equipment / Tools': 'other'}
# Prices the transcription had to guess: loaded without a price until the supplier confirms.
HOLD = {('IAN Solar', 'S6-EH3P30K-H-LV'): "printed as '259,00' on the list; 259,000 was a guess"}
UNIT = {'pc': 'piece', 'pcs': 'piece', 'set': 'set', 'pair': 'set', 'mtr': 'meter', 'roll': 'roll', 'kwh': 'kwh', 'box': 'box'}


def price_basis(text):
    t = (text or '').lower()
    if 'not landed' in t or 'factory' in t or 'pick-up' in t or 'ex-warehouse' in t:
        return 'exw'
    if 'free delivery' in t or 'delivered' in t:
        return 'delivered'
    if 'srp' in t and 'tiers' not in t:  # an SRP-only list; multi-tier lists just mention SRP
        return 'retail'
    return None


def product_name(brand, text):
    # descriptions often start with the brand already ("SUNGROW 6.0kW hybrid")
    if not brand or (text or '').lower().startswith(brand.split(' (')[0].lower()):
        return text or brand or 'Unnamed'
    return f'{brand} {text}' if text else brand


suppliers = {r['supplier']: r for r in csv.DictReader(open(suppliers_file, encoding='utf-8-sig'))}
docs = {}
skipped = []
for r in csv.DictReader(open(quotes_file, encoding='utf-8-sig')):
    sup = suppliers.get(r['supplier'], {})
    name, domain, kind, country = REGISTER.get(r['supplier'], (r['supplier'], None, None, None))
    try:
        price = float(r['price_quoted'].replace(',', '')) if r['price_quoted'].strip() else None
    except ValueError:
        skipped.append((r['supplier'], r['model'], r['price_quoted']))
        continue
    held = HOLD.get((r['supplier'], r['model']))
    if held:
        price = None
    key = (r['supplier'], r['source_file'], r['quote_date'])
    if key not in docs:
        docs[key] = {
            'sender_email': None, 'sender_domain': domain, 'company': name, 'kind': kind, 'country': country,
            'thread_id': None, 'message_id': None, 'filename': r['source_file'],
            'message_date': r['quote_date'] or None, 'document_date': r['quote_date'] or None, 'valid_until': None,
            'currency': 'PHP', 'price_basis': price_basis(sup.get('price_basis')),
            'vat_included': sup.get('vat_basis_used') == 'inc', 'doc_kind': 'price_list', 'read_status': 'read',
            'products': [], 'terms': sup.get('terms_note') or None,
            'notes': f"From the COO's supplier price-list folder; transcribed {r['ingest_date']}. Price validity: {r['price_validity'] or 'not stated'}.",
        }
    tier = r['price_tier'] if r['price_tier'] not in ('', 'Standard', 'List') else ''
    list_tier = r['price_tier'] == 'List' and 'List' not in (sup.get('default_tiers') or '')
    default_tiers = (sup.get('default_tiers') or 'Standard').split('|')
    size = f"{r['size_value']} {r['size_unit']}".strip() if r['size_value'] else ''
    unit_raw = r['unit'].lower().split(' ')[0]
    docs[key]['products'].append({
        'name': product_name(r['brand'], r['description'] or r['model'])[:200] + (f' ({tier})' if tier else ''),
        'model': r['model'] or None, 'brand': r['brand'] or None,
        'category': CATEGORY.get(r['category'], 'bos'),
        'specs': '; '.join(x for x in [size, r['description']] if x) or None,
        'price': price, 'currency': 'PHP', 'unit': UNIT.get(unit_raw, 'piece'), 'min_qty': 1,
        'price_basis': None,
        # a row-level "inc" overrides the supplier's VAT basis
        'vat_included': True if r['vat_basis'] == 'inc' else None,
        'notes': '; '.join(x for x in [
            f"tier: {r['price_tier']}" + ('' if r['price_tier'] in default_tiers or not tier else ' (not the default comparison tier)') if tier else '',
            'tier: List (not the default comparison tier)' if list_tier else '',
            held and f'price held: {held}',
            f"category: {r['category']}", r['availability'], r['packing'] and f"packing: {r['packing']}",
            r['notes'], r['flag'] and f"flag: {r['flag']}",
        ] if x) or None,
    })

out = list(docs.values())
json.dump(out, open(out_file, 'w'), indent=1, ensure_ascii=False)
print(json.dumps({'files': len(out), 'lines': sum(len(d['products']) for d in out),
                  'priced': sum(1 for d in out for p in d['products'] if p['price'] is not None),
                  'skipped': skipped}))
