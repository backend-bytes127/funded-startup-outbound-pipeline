#!/usr/bin/env bash
# Finds and validates work emails via LeadMagic
# Usage: ./scripts/04_find_emails.sh [pilot|full]
set -euo pipefail

set -a; source .env.deepline; set +a

WORKDIR="deepline/data"
IN="$WORKDIR/contacts_flat.csv"
OUT="$WORKDIR/contacts_with_email.csv"
MODE="${1:-pilot}"
ROWS_FLAG=$([ "$MODE" = "full" ] && echo "--all" || echo "--rows 0:0")

echo ">>> Mode: $MODE | $ROWS_FLAG"

echo "=== Pass 1: Find work email via LeadMagic ==="
WITH_EMAIL=$(python3 -c "import json; print(json.dumps({'alias':'email_result','tool':'leadmagic_email_finder','payload':{'name':'{{full_name}}','domain':'{{domain}}'}}))")
deepline enrich --input "$IN" --output "$OUT" --name find-emails $ROWS_FLAG --with "$WITH_EMAIL"

echo "=== Pass 2: Validate email ==="
WITH_VAL=$(python3 -c "import json; print(json.dumps({'alias':'email_validation','tool':'leadmagic_email_validation','payload':{'email':'{{email_result.email}}'}}))")
deepline enrich --input "$OUT" --in-place --name validate-emails $ROWS_FLAG --with "$WITH_VAL"

echo "=== Pass 3: Filter to valid emails only ==="
python3 - "$OUT" "$WORKDIR/contacts_verified.csv" <<'PYEOF'
import csv, json, sys

VALID_STATUSES = {'valid', 'valid_catch_all', 'catch_all'}

def parse_result(row, col):
    raw = row.get(col, '') or ''
    try:
        d = json.loads(raw) if isinstance(raw, str) else raw
        if isinstance(d, dict):
            return d.get('extracted_json') or d.get('result',{}).get('object') or d
        return {}
    except Exception:
        return {}

with open(sys.argv[1], newline='', encoding='utf-8') as fin, \
     open(sys.argv[2], 'w', newline='', encoding='utf-8') as fout:
    reader = csv.DictReader(fin)
    base_fields = [f for f in reader.fieldnames if f not in ('email_result','email_validation')]
    out_fields = base_fields + ['email', 'email_status']
    # Reset reader
    fin.seek(0); next(fin)
    writer = csv.DictWriter(fout, fieldnames=out_fields)
    writer.writeheader()
    total, kept = 0, 0
    for row in csv.DictReader(open(sys.argv[1])):
        total += 1
        er = parse_result(row, 'email_result')
        ev = parse_result(row, 'email_validation')
        email = (er.get('email') or '').strip().lower()
        status = (ev.get('status') or ev.get('result') or '').lower()
        if not email or status not in VALID_STATUSES:
            continue
        out_row = {f: row.get(f,'') for f in base_fields}
        out_row['email'] = email
        out_row['email_status'] = status
        writer.writerow(out_row)
        kept += 1
    print(f'Verified: {kept}/{total} contacts with valid emails → {sys.argv[2]}')
PYEOF

echo "Done. Run full: ./scripts/04_find_emails.sh full"
