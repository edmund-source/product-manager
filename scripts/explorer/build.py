#!/usr/bin/env python3
"""Builds the Partner explorer page (a claude.ai artifact) from the merged extract.

  python3 -I scripts/explorer/build.py data/suppliers_merged.json data/all_price_files.json out.html \
      [--date YYYY-MM-DD] [--fx USD=63.07,CNY=9.43] [--evidence data/stage_evidence.json] \
      [--fin-summary data/fin_summary.json] [--trigger trig_...] [--schedule "Mondays, 6:37 am Manila"]

Contacts keep name and title only; emails and phone numbers anywhere in the
data are replaced before the page is written. See
.claude/skills/explorer-refresh/SKILL.md for the weekly refresh."""
import json, re, sys, os, datetime

args = sys.argv[1:]
src, att_src, out = args[0], args[1], args[2]
fx = {'USD': 63.07, 'CNY': 9.43}  # BSP reference rates, 19 Oct 2026
gen = datetime.date.today().isoformat()
evidence = {}
fin_summary_file = None
refresh = {}
for i, a in enumerate(args):
    if a == '--fin-summary':
        fin_summary_file = args[i + 1]
    if a == '--trigger':
        refresh['trigger'] = args[i + 1]
    if a == '--schedule':
        refresh['schedule'] = args[i + 1]
    if a == '--evidence':
        for e in json.load(open(args[i + 1])):
            evidence[e['company']] = e
    if a == '--fx':
        for kv in args[i + 1].split(','):
            k, v = kv.split('=')
            fx[k.upper()] = float(v)
    if a == '--date':
        gen = args[i + 1]

companies = json.load(open(src))
files_read = 0
file_info = {}
if att_src != '-' and os.path.exists(att_src):
    att_docs = json.load(open(att_src))
    files_read = sum(1 for d in att_docs if str(d.get('read_status', '')).startswith(('read', 'scanned')))
    for d in att_docs:
        file_info[d['filename']] = {'date': d.get('document_date') or d.get('message_date'), 'terms': d.get('terms'),
                                    'notes': d.get('notes'), 'status': d.get('read_status'), 'kind': d.get('doc_kind'),
                                    'thread': d.get('thread_id')}

EQUIP = {'inverters', 'panels', 'batteries', 'mounting', 'bos', 'ev_charging', 'appliances'}
CAT_ALIASES = {'inverter': 'inverters', 'panel': 'panels', 'modules': 'panels', 'pv_modules': 'panels', 'module': 'panels',
               'battery': 'batteries', 'bess': 'batteries', 'energy_storage': 'batteries', 'racking': 'mounting',
               'ats': 'bos', 'cable': 'bos', 'cables': 'bos', 'electrical': 'bos', 'ev_charger': 'ev_charging',
               'ev_chargers': 'ev_charging', 'equipment': 'other', 'microinverter': 'inverters',
               'battery_solar_kit': 'batteries', 'portable_power_station': 'batteries', 'solar_pump': 'other',
               'appliance': 'appliances', 'furniture': 'other',
               'payment_fee': 'payments', 'payment_gateway_fee': 'payments', 'installment_subsidy': 'payments',
               'credit_line': 'financing', 'loan': 'financing', 'referral_fee': 'service', 'delivery': 'service',
               'freight': 'service', 'warehousing': 'service', 'sourcing_service': 'service', 'marketing': 'service',
               'software_subscription': 'software'}
FIN_KINDS = {'financing', 'bank', 'lender', 'investor', 'insurer'}

def slug(s):
    return re.sub(r'[^a-z0-9]+', '_', str(s or '').lower()).strip('_')

def num(rx, text):
    m = re.search(rx, text, re.I)
    return float(m.group(1)) if m else None

def ratings(cat, text, model):
    t = f'{text} {model or ""}'
    w = kwh = kw = None
    if cat == 'panels':
        w = num(r'(?<![\d.])(\d{3,4}(?:\.\d+)?)\s*(?:W|Wp)\b', t)
        if w and not 100 <= w <= 1000:
            w = None
    if cat == 'batteries':
        kwh = num(r'(?<![\d.])(\d{1,3}(?:\.\d+)?)\s*kWh', t)
        if kwh is None:
            m = re.search(r'(?<![\d.])(\d{1,3}(?:\.\d+)?)\s*V\b.{0,40}?(?<![\d.])(\d{2,4})\s*Ah', t, re.I)
            if m:
                kwh = round(float(m.group(1)) * float(m.group(2)) / 1000, 2)
        if kwh and not 0.5 <= kwh <= 500:
            kwh = None
    if cat == 'inverters':
        kw = num(r'(?<![\d.])(\d{1,3}(?:\.\d+)?)\s*kW(?!h)', t)
        if kw is None:
            # model codes like SUN-SL-HP6K-A1 or SUN-6K-SG
            for m_ in re.finditer(r'(?<![\d.])(\d{1,2}(?:\.\d)?)\s?K(?:W)?(?![A-Za-z0-9])', model or ''):
                kw = float(m_.group(1)); break
        if kw is None:
            w_ = num(r'(?<![\d.])(\d{3,5})\s*W\b', t)
            kw = w_ / 1000 if w_ else None
        if kw and not 0.3 <= kw <= 150:
            kw = None
    return w, kwh, kw

def short_name(n):
    n = re.sub(r'\s*\(.*?\)', '', n)
    n = re.sub(r'\s+-\s+.*$', '', n)
    n = re.sub(r',?\s+(Inc\.?|Corporation|Corp\.|Co\., Ltd\.|Ltd\.|OPC|Fund Management)$', '', n)
    return n.strip() or n

out_companies, lines = [], []
for i, c in enumerate(companies):
    cid = f'c{i}'
    types = [t for t in (c.get('partner_types') or []) if t] or ['other']
    out_companies.append({
        'id': cid, 'name': c.get('company') or '—', 'domain': c.get('website_domain'), 'country': c.get('country'),
        'ph': c.get('ph_presence'), 'kind': c.get('kind') or 'other', 'types': types, 'solar': c.get('solar_related', True),
        'status': c.get('status') or 'unknown', 'brands': c.get('brands') or [], 'first': c.get('first_contact'),
        'last': c.get('last_contact'), 'intro': c.get('introduced_by'), 'summary': c.get('summary'),
        'next': c.get('next_step'), 'threads': c.get('thread_ids') or [], 'attachments': c.get('has_attachments') or [],
        'contacts': [{'name': p.get('name'), 'title': p.get('title')} for p in (c.get('contacts') or []) if p.get('name')],
        'short': short_name(c.get('company') or '—'),
        'evidence': (lambda e: e and {'verdict': e.get('verdict'), 'basis': e.get('basis'), 'suggested': e.get('suggested_status'),
                                      'emails': e.get('evidence') or [], 'contracts': e.get('contract_files') or []})(evidence.get(c.get('company'))),
    })
    fin_company = c.get('kind') in FIN_KINDS
    for p in c.get('products') or []:
        cat = slug(p.get('category'))
        cat = CAT_ALIASES.get(cat, cat)
        if fin_company and cat not in EQUIP:
            cat = 'financing'
        elif cat not in EQUIP and cat not in {'financing', 'insurance', 'payments', 'service', 'software'}:
            cat = 'other'
        source = p.get('source') or 'email body'
        is_att = source.lower().startswith('attachment')
        text = ' '.join(str(x) for x in [p.get('name'), p.get('specs'), p.get('notes')] if x)
        w, kwh, kw = ratings(cat, text, p.get('model'))
        # a price with no currency is a percentage (fees, rates, subsidies)
        cur = (p.get('currency') or ('%' if p.get('price') is not None else 'PHP')).upper()[:3]
        price = p.get('price')
        if isinstance(price, str):
            try:
                price = float(price.replace(',', ''))
            except ValueError:
                price = None
        notes = p.get('notes')
        terms = (file_info.get(source.split(':', 1)[1].strip(), {}).get('terms') if is_att else None)
        if notes and terms and terms in notes:  # file terms are shown once per file in the supplier view
            notes = notes.replace(terms, '').strip('; ').strip() or None
        tier = re.search(r'tier: ([^;(]+)', notes or '')
        if notes:  # brand, tier and category have their own place in the view
            notes = re.sub(r'(?:^|;\s*)(?:brand|tier|category): [^;]*', '', notes).strip('; ').strip() or None
        lines.append({
            'cid': cid, 'name': p.get('name') or 'Unnamed', 'model': p.get('model'), 'cat': cat, 'price': price,
            'cur': cur, 'unit': (p.get('unit') or 'piece').lower(), 'moq': p.get('min_qty') or 1,
            'basis': p.get('price_basis'), 'vat': p.get('vat_included'), 'quoted': p.get('quoted_on'),
            'valid': p.get('valid_until'), 'src': 'attachment' if is_att else 'email',
            'file': source.split(':', 1)[1].strip() if is_att else None, 'specs': p.get('specs'),
            'notes': notes, 'tier': tier.group(1).strip() if tier else None, 'thread': p.get('thread_id'), 'w': w, 'kwh': kwh, 'kw': kw,
            # a tier the price list's owner chose not to compare on (SRP, installer, other region)
            'alt': 'not the default comparison tier' in (p.get('notes') or ''),
            'phase': (3 if re.search(r'\b3\s?P\b|3-?phase|three[- ]phase|400\s?V|380\s?V|EH3P|3PH', f"{p.get('name')} {p.get('model')} {p.get('specs')}", re.I) else 1) if cat == 'inverters' else None,
        })

fin_types = {'consumer_financing', 'business_financing', 'investment', 'insurance', 'payments'}
equip_types = {'inverters', 'panels', 'batteries', 'mounting', 'bos', 'equipment', 'ev_charging', 'appliances'}
data = {
    'generated': gen, 'mailbox': 'edmund@joinhelios.com', 'fx': fx,
    'stats': {
        'companies': len(out_companies),
        'equipment': sum(1 for c in out_companies if set(c['types']) & equip_types),
        'financial': sum(1 for c in out_companies if set(c['types']) & fin_types),
        'priced': sum(1 for l in lines if l['price'] is not None and l['cat'] in EQUIP),
        'files': files_read,
    },
    'footnote': ('Sources: keyword searches of Edmund\'s Gmail, the price lists, quotes and catalogs attached to those emails, '
                 'and the supplier price lists compiled by Tim (Photonergy, IAN Solar, EcoSolutions, Power AI, FIREFLY, Gankong, Goodwell), read by Claude. '
                 'Where a list has several tiers, the comparison uses the tier Tim chose; the others show when you untick Comparison tier only. Prices are as quoted; ex-VAT figures divide by 1.12 only where the quote says VAT is included. '
                 'Foreign currencies use the rates in the bar above, which you can change. Contact emails and phone numbers are left out of this page.'),
    'finSummary': json.load(open(fin_summary_file)) if fin_summary_file and os.path.exists(fin_summary_file) else {},
    'refresh': refresh,
    'companies': out_companies, 'lines': lines,
    'files': {f: v for f, v in file_info.items() if any(l['file'] == f for l in lines) or any(f in c['attachments'] for c in out_companies)},
}
EMAIL = re.compile(r'[\w.+-]+@[\w-]+\.[\w.]+')
PHONE = re.compile(r'(?:\+?63|0)9\d{2}[\s-]?\d{3}[\s-]?\d{4}|\+\d{1,3}[\s-]?\(?\d{2,4}\)?[\s-]?\d{3,4}[\s-]?\d{3,4}')

def scrub(v):
    # contact details stay out of the page, even inside summaries and notes
    if isinstance(v, str):
        return PHONE.sub('[phone removed]', EMAIL.sub(lambda m: m.group(0) if m.group(0) == data['mailbox'] else '[email removed]', v))
    if isinstance(v, list):
        return [scrub(x) for x in v]
    if isinstance(v, dict):
        return {k: (x if k == 'mailbox' else scrub(x)) for k, x in v.items()}
    return v

data = scrub(data)
blob = json.dumps(data, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/')
tpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'template.html')).read()
import base64
avatar_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'marie-avatar.webp')
avatar = base64.b64encode(open(avatar_file, 'rb').read()).decode() if os.path.exists(avatar_file) else ''
marie_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'marie.md')
marie = re.sub(r'<!--.*?-->', '', open(marie_file).read(), flags=re.S).strip()
marie = json.dumps(marie, ensure_ascii=False).replace('</', '<\\/')
open(out, 'w').write(tpl.replace('/*DATA*/', blob).replace('AVATAR_B64', avatar).replace("/*MARIE*/''", marie))
placed = {k: sum(1 for l in lines if l['cat'] == k and l['price'] is not None and (l[m] or l['unit'] == u)) for k, m, u in [('panels', 'w', 'watt'), ('batteries', 'kwh', 'kwh'), ('inverters', 'kw', 'kw')]}
priced = {k: sum(1 for l in lines if l['cat'] == k and l['price'] is not None) for k in placed}
print(json.dumps({'out': out, 'bytes': os.path.getsize(out), **data['stats'], 'lines': len(lines), 'placed_on_chart': placed, 'priced_by_cat': priced}))
