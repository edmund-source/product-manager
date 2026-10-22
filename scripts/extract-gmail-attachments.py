#!/usr/bin/env python3
"""Usage: python3 -I scripts/extract-gmail-attachments.py <raw-json-file> [out-root]
Decodes a Gmail RAW get_message result, saves each attachment to
<out-root>/<message-id>/ and writes a .txt next to every PDF, XLSX and DOCX.
Prints one line per attachment: path, size, text chars."""
import base64, email, json, os, re, subprocess, sys, zipfile
from email import policy

src = sys.argv[1]
root = sys.argv[2] if len(sys.argv) > 2 else 'data/attachments'
data = json.load(open(src))
raw = data['raw']
raw += '=' * (-len(raw) % 4)
msg = email.message_from_bytes(base64.urlsafe_b64decode(raw), policy=policy.default)
out = os.path.join(root, data['id'])
os.makedirs(out, exist_ok=True)
print(f"message {data['id']} thread {data['threadId']} subject: {msg['subject']}")

def to_text(path):
    low = path.lower()
    txt = path + '.txt'
    try:
        if low.endswith('.pdf'):
            subprocess.run(['pdftotext', '-layout', path, txt], check=True, timeout=120,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif low.endswith(('.xlsx', '.xlsm')):
            # minimal xlsx reader: shared strings + sheet cell values, row by row
            z = zipfile.ZipFile(path)
            ss = []
            if 'xl/sharedStrings.xml' in z.namelist():
                x = z.read('xl/sharedStrings.xml').decode('utf8', 'replace')
                for si in re.findall(r'<si>(.*?)</si>', x, re.S):
                    ss.append(''.join(re.findall(r'<t[^>]*>(.*?)</t>', si, re.S)))
            lines = []
            for name in sorted(n for n in z.namelist() if n.startswith('xl/worksheets/sheet')):
                lines.append(f'=== {name}')
                x = z.read(name).decode('utf8', 'replace')
                for row in re.findall(r'<row[^>]*>(.*?)</row>', x, re.S):
                    cells = []
                    for attrs, body in re.findall(r'<c([^>]*)>(.*?)</c>', row, re.S):
                        v = re.search(r'<v>(.*?)</v>', body, re.S)
                        t = re.search(r'<t[^>]*>(.*?)</t>', body, re.S)
                        val = v.group(1) if v else (t.group(1) if t else '')
                        if 't="s"' in attrs and val.isdigit() and int(val) < len(ss):
                            val = ss[int(val)]
                        cells.append(val)
                    if any(cells):
                        lines.append(' | '.join(cells))
            open(txt, 'w').write('\n'.join(lines))
        elif low.endswith('.docx'):
            x = zipfile.ZipFile(path).read('word/document.xml').decode('utf8', 'replace')
            open(txt, 'w').write(re.sub(r'<[^>]+>', ' ', x.replace('</w:p>', '\n')))
        elif low.endswith(('.csv', '.txt')):
            return os.path.getsize(path)
        else:
            return None
        return os.path.getsize(txt) if os.path.exists(txt) else 0
    except Exception as e:
        return f'error: {e}'

n = 0
for part in msg.walk():
    fn = part.get_filename()
    if not fn or part.is_multipart():
        continue
    payload = part.get_payload(decode=True) or b''
    safe = re.sub(r'[^A-Za-z0-9._ -]+', '_', fn).strip() or f'attachment{n}'
    path = os.path.join(out, safe)
    open(path, 'wb').write(payload)
    n += 1
    print(f'{path}\t{len(payload)} bytes\ttext: {to_text(path)}')
if not n:
    print('no attachments')
