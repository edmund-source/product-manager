#!/usr/bin/env python3
"""Writes the copies of the extracts that are stored inside the explorer
artifact (state/), with contact details removed: contacts keep name and
title, attachment records keep the sender's domain, and any email address or
phone number left in free text is replaced.

  python3 -I scripts/explorer/scrub-state.py data
"""
import json
import os
import re
import sys

d = sys.argv[1] if len(sys.argv) > 1 else 'data'
EMAIL = re.compile(r'[\w.+-]+@[\w-]+\.[\w.]+')
PHONE = re.compile(r'(?:\+?63|0)9\d{2}[\s-]?\d{3}[\s-]?\d{4}|\+\d{1,3}[\s-]?\(?\d{2,4}\)?[\s-]?\d{3,4}[\s-]?\d{3,4}')


def scrub(v):
    if isinstance(v, str):
        return PHONE.sub('[phone removed]', EMAIL.sub('[email removed]', v))
    if isinstance(v, list):
        return [scrub(x) for x in v]
    if isinstance(v, dict):
        return {k: scrub(x) for k, x in v.items()}
    return v


suppliers = json.load(open(os.path.join(d, 'suppliers_from_gmail.json')))
for c in suppliers:
    c['contacts'] = [{'name': p.get('name'), 'title': p.get('title')} for p in c.get('contacts') or [] if p.get('name')]
files = json.load(open(os.path.join(d, 'attachment_prices.json')))
for f in files:
    f.pop('sender_email', None)
out = {'state_suppliers.json': suppliers, 'state_attachments.json': files,
       'state_evidence.json': json.load(open(os.path.join(d, 'stage_evidence.json')))}
for name, data in out.items():
    json.dump(scrub(data), open(os.path.join(d, name), 'w'), indent=1, ensure_ascii=False)
    print(name, len(data))
