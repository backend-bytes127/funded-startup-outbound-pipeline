#!/usr/bin/env bash
# Writes personalized cold emails for each verified contact using company funding context
# Usage: ./scripts/05_write_copy.sh [pilot|full]
set -euo pipefail

set -a; source .env.deepline; set +a

WORKDIR="deepline/data"
IN="$WORKDIR/contacts_verified.csv"
OUT="$WORKDIR/contacts_with_copy.csv"
MODE="${1:-pilot}"
ROWS_FLAG=$([ "$MODE" = "full" ] && echo "--all" || echo "--rows 0:0")

echo ">>> Mode: $MODE | $ROWS_FLAG"
echo "=== Write personalized cold email for each contact ==="

WITH_COPY=$(python3 -c "
import json
prompt = '''Write a short, personalized cold email for {{first_name}} {{last_name}}, {{job_title}} at {{company_name}}.

Company context:
- Recently raised {{funding_amount}} from {{vc_name}}
- Top competitors: {{competitors}}
- Employee count: {{employee_count}}

Guidelines:
- Under 120 words total
- First line references their recent funding (shows you did research)
- One clear value prop relevant to their role and growth stage post-funding
- Single CTA: ask for a 15-minute call
- No generic openers like I hope this email finds you well
- Sound like a peer not a vendor

Return subject line on first line starting with Subject:, then the email body.'''

print(json.dumps({'alias':'copy_result','tool':'deeplineagent','payload':{'prompt':prompt,'jsonSchema':{'type':'object','properties':{'subject':{'type':'string'},'email_body':{'type':'string','description':'Email body only, no subject line'}},'required':['subject','email_body']}}}))")
deepline enrich --input "$IN" --output "$OUT" --name write-copy $ROWS_FLAG --with "$WITH_COPY"

echo "=== Flatten copy into final CSV ==="
python3 - "$OUT" "$WORKDIR/contacts_final.csv" <<'PYEOF'
import csv, json, sys

def parse_deepline(row, col):
    raw = row.get(col, '') or ''
    try:
        d = json.loads(raw)
        if isinstance(d, dict):
            return d.get('extracted_json') or d.get('result',{}).get('object') or d
        return {}
    except Exception:
        return {}

out_fields = ['first_name','last_name','full_name','email','email_status',
              'job_title','linkedin_url','company_name','domain','location',
              'funding_amount','vc_name','competitors','employee_count',
              'email_subject','email_body']

with open(sys.argv[1], newline='', encoding='utf-8') as fin, \
     open(sys.argv[2], 'w', newline='', encoding='utf-8') as fout:
    reader = csv.DictReader(fin)
    writer = csv.DictWriter(fout, fieldnames=out_fields)
    writer.writeheader()
    count = 0
    for row in reader:
        copy = parse_deepline(row, 'copy_result')
        writer.writerow({
            'first_name': row.get('first_name',''), 'last_name': row.get('last_name',''),
            'full_name': row.get('full_name',''), 'email': row.get('email',''),
            'email_status': row.get('email_status',''), 'job_title': row.get('job_title',''),
            'linkedin_url': row.get('linkedin_url',''), 'company_name': row.get('company_name',''),
            'domain': row.get('domain',''), 'location': row.get('location',''),
            'funding_amount': row.get('funding_amount',''), 'vc_name': row.get('vc_name',''),
            'competitors': row.get('competitors',''), 'employee_count': row.get('employee_count',''),
            'email_subject': copy.get('subject',''), 'email_body': copy.get('email_body',''),
        })
        count += 1
print(f'Final CSV: {count} contacts with copy → {sys.argv[2]}')
PYEOF

echo "Done. Run full: ./scripts/05_write_copy.sh full"
