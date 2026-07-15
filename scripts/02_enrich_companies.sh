#!/usr/bin/env bash
# AI-enriches each RSS item: article URL → company name/URL → funding/VC → competitors → company data
# Usage: ./scripts/02_enrich_companies.sh [pilot|full]  (default: pilot = 1 row)
set -euo pipefail

set -a; source .env.deepline; set +a

WORKDIR="deepline/data"
SEED="$WORKDIR/seed_companies.csv"
WORK="$WORKDIR/enriched_companies.csv"
MODE="${1:-pilot}"
ROWS_FLAG=$([ "$MODE" = "full" ] && echo "--all" || echo "--rows 0:0")

echo ">>> Mode: $MODE | $ROWS_FLAG"

echo "=== Pass 1: Find article URL from title ==="
WITH1=$(python3 -c "import json; print(json.dumps({'alias':'article_data','tool':'deeplineagent','payload':{'prompt':'Given the title: {{title}} — find the correct news article URL that covers this story. Return only the URL.','jsonSchema':{'type':'object','properties':{'article_url':{'type':'string'}},'required':['article_url']}}}))")
deepline enrich --input "$SEED" --output "$WORK" --name rss-p1-article $ROWS_FLAG --force --with "$WITH1"

echo "=== Pass 2: Extract company name and URL ==="
WITH2=$(python3 -c "import json; print(json.dumps({'alias':'company_details','tool':'deeplineagent','payload':{'prompt':'Given the article at {{article_data.article_url}} (title: {{title}}), find the startup company name and company website URL that raised the funding. Return the startup that raised money, not the VC.','jsonSchema':{'type':'object','properties':{'company_name':{'type':'string'},'company_url':{'type':'string'}},'required':['company_name','company_url']}}}))")
deepline enrich --input "$WORK" --in-place --name rss-p2-company $ROWS_FLAG --with "$WITH2"

echo "=== Pass 3: Find funding amount and VC ==="
WITH3=$(python3 -c "import json; print(json.dumps({'alias':'funding_data','tool':'deeplineagent','payload':{'prompt':'For {{company_details.company_name}} ({{company_details.company_url}}), find how much money was raised and which VC led the round. Use article at {{article_data.article_url}} as source.','jsonSchema':{'type':'object','properties':{'funding_amount':{'type':'string'},'vc_name':{'type':'string'}},'required':['funding_amount','vc_name']}}}))")
deepline enrich --input "$WORK" --in-place --name rss-p3-funding $ROWS_FLAG --with "$WITH3"

echo "=== Pass 4: Find top 5 competitors ==="
WITH4=$(python3 -c "import json; print(json.dumps({'alias':'competitors_data','tool':'deeplineagent','payload':{'prompt':'List the top 5 competitors of {{company_details.company_name}} (website: {{company_details.company_url}}). Return only company names, one per line.','jsonSchema':{'type':'object','properties':{'competitors':{'type':'string','description':'Top 5 competitor names, newline-separated'}},'required':['competitors']}}}))")
deepline enrich --input "$WORK" --in-place --name rss-p4-competitors $ROWS_FLAG --with "$WITH4"

echo "=== Pass 5: Crustdata company enrich ==="
WITH5=$(python3 -c "import json; print(json.dumps({'alias':'company_enrich','tool':'crustdata_v3_company_enrich','payload':{'domains':['{{company_details.company_url}}'],'exact_match':False}}))")
deepline enrich --input "$WORK" --in-place --name rss-p5-crustdata $ROWS_FLAG --with "$WITH5"

echo "=== Pass 5b: LeadMagic company search fallback ==="
WITH5B=$(python3 -c "import json; print(json.dumps({'alias':'leadmagic_enrich','tool':'leadmagic_company_search','payload':{'domain':'{{company_details.company_url}}'}}))")
deepline enrich --input "$WORK" --in-place --name rss-p5b-leadmagic $ROWS_FLAG --with "$WITH5B"

echo "=== Pass 6: Flatten and output qualified companies ==="
python3 - "$WORK" "$WORKDIR/companies_qualified.csv" <<'PYEOF'
import csv, json, sys

def parse_deepline(row, col):
    raw = row.get(col, '') or ''
    if not raw: return {}
    try:
        d = json.loads(raw)
    except Exception:
        return {}
    if isinstance(d, dict):
        return d.get('extracted_json') or d.get('result',{}).get('object') or d
    return {}

def get_employee_count(row):
    ce_raw = row.get('company_enrich', '') or ''
    if ce_raw:
        try:
            ce = json.loads(ce_raw)
            matches = ce if isinstance(ce, list) else ce.get('matches', [])
            for match in matches:
                cd = match.get('company_data', {}) or {}
                hc = cd.get('headcount')
                if isinstance(hc, dict):
                    val = hc.get('current') or hc.get('value')
                    if val: return int(val)
                elif isinstance(hc, (int, float)):
                    return int(hc)
        except Exception:
            pass
    lm_raw = row.get('leadmagic_enrich', '') or ''
    if lm_raw.startswith('{'):
        try:
            lm = json.loads(lm_raw)
            ec = lm.get('employeecount') or lm.get('employee_count') or lm.get('headcount')
            if ec: return int(str(ec).replace(',',''))
        except Exception:
            pass
    return 0

with open(sys.argv[1], newline='', encoding='utf-8') as fin, \
     open(sys.argv[2], 'w', newline='', encoding='utf-8') as fout:
    reader = csv.DictReader(fin)
    out_fields = ['title','article_url','company_name','company_url','domain',
                  'funding_amount','vc_name','competitors','industry','employee_count']
    writer = csv.DictWriter(fout, fieldnames=out_fields)
    writer.writeheader()
    total = 0
    for row in reader:
        total += 1
        cd = parse_deepline(row, 'company_details')
        fd = parse_deepline(row, 'funding_data')
        comp = parse_deepline(row, 'competitors_data')
        ad = parse_deepline(row, 'article_data')
        company_url = (cd.get('company_url') or '').strip()
        domain = company_url.replace('https://','').replace('http://','').replace('www.','').split('/')[0]
        writer.writerow({
            'title': row.get('title',''),
            'article_url': ad.get('article_url',''),
            'company_name': cd.get('company_name',''),
            'company_url': company_url,
            'domain': domain,
            'funding_amount': fd.get('funding_amount',''),
            'vc_name': fd.get('vc_name',''),
            'competitors': comp.get('competitors',''),
            'industry': '',
            'employee_count': get_employee_count(row),
        })

print(f'Wrote {total} rows → {sys.argv[2]}')
PYEOF

echo "Done. Run full: ./scripts/02_enrich_companies.sh full"
