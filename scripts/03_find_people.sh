#!/usr/bin/env bash
# Finds Senior Marketing, Sales, CRO contacts at enriched companies (US + Canada)
# Usage: ./scripts/03_find_people.sh [pilot|full]
set -euo pipefail

set -a; source .env.deepline; set +a

WORKDIR="deepline/data"
IN="$WORKDIR/companies_qualified.csv"
OUT="$WORKDIR/contacts_raw.csv"
MODE="${1:-pilot}"
ROWS_FLAG=$([ "$MODE" = "full" ] && echo "--all" || echo "--rows 0:0")

echo ">>> Mode: $MODE | $ROWS_FLAG"
echo "=== Find people: Marketing/Sales/CRO at each company in US + Canada ==="

WITH_P=$(python3 -c "import json; print(json.dumps({'alias':'people_results','tool':'crustdata_v2_people_search_realtime','payload':{'filters':[{'filter_type':'CURRENT_COMPANY','type':'in','value':['{{company_name}}']},{'filter_type':'CURRENT_TITLE','type':'in','value':['VP Marketing','VP Sales','Chief Revenue Officer','CRO','Chief Marketing Officer','CMO','Head of Marketing','Head of Sales','Director of Marketing','Director of Sales','VP of Marketing','VP of Sales']},{'filter_type':'REGION','type':'in','value':['United States','Canada']}],'page':1}}))")
deepline enrich --input "$IN" --output "$OUT" --name find-people $ROWS_FLAG --with "$WITH_P"

echo "=== Flatten: one row per contact ==="
python3 - "$OUT" "$WORKDIR/contacts_flat.csv" <<'PYEOF'
import csv, json, sys

out_fields = ['first_name','last_name','full_name','job_title','linkedin_url',
              'company_name','company_url','domain','location',
              'funding_amount','vc_name','competitors','industry','employee_count']

with open(sys.argv[1], newline='', encoding='utf-8') as fin, \
     open(sys.argv[2], 'w', newline='', encoding='utf-8') as fout:
    reader = csv.DictReader(fin)
    writer = csv.DictWriter(fout, fieldnames=out_fields)
    writer.writeheader()
    total = 0
    for row in reader:
        raw = row.get('people_results', '') or ''
        try:
            d = json.loads(raw) if isinstance(raw, str) else raw
        except Exception:
            d = {}
        # Result is in toolResponse.raw.profiles (when called via enrich)
        # or at extracted_json level
        if isinstance(d, dict):
            profiles = (d.get('toolResponse', {}).get('raw', {}).get('profiles')
                       or d.get('profiles')
                       or d.get('results')
                       or d.get('data')
                       or [])
        elif isinstance(d, list):
            profiles = d
        else:
            profiles = []

        for p in profiles:
            if not p: continue
            name = p.get('name') or p.get('full_name') or ''
            parts = name.strip().split(' ', 1)
            fname = parts[0] if parts else ''
            lname = parts[1] if len(parts) > 1 else ''
            writer.writerow({
                'first_name': fname,
                'last_name': lname,
                'full_name': name,
                'job_title': p.get('default_position_title') or p.get('title') or '',
                'linkedin_url': p.get('linkedin_profile_url') or p.get('url') or '',
                'company_name': row.get('company_name', ''),
                'company_url': row.get('company_url', ''),
                'domain': row.get('domain', ''),
                'location': p.get('location') or '',
                'funding_amount': row.get('funding_amount', ''),
                'vc_name': row.get('vc_name', ''),
                'competitors': row.get('competitors', ''),
                'industry': row.get('industry', ''),
                'employee_count': row.get('employee_count', ''),
            })
            total += 1

print(f'Flattened {total} contacts → {sys.argv[2]}')
PYEOF

echo "Done. Run full: ./scripts/03_find_people.sh full"
