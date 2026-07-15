#!/usr/bin/env bash
# AI-enriches each RSS item: article URL → company name/URL → funding/VC → competitors → company data
# Runs a one-row pilot first; pass "full" to run all rows.
set -euo pipefail

set -a; source .env.deepline; set +a
: "${SMARTLEAD_API_KEY:?SMARTLEAD_API_KEY must be set in .env.deepline}"

WORKDIR="deepline/data"
SEED="$WORKDIR/seed_companies.csv"
WORK="$WORKDIR/enriched_companies.csv"
MODE="${1:-pilot}"

rows_flag() {
  [ "$MODE" = "full" ] && echo "" || echo "--rows 0:1"
}

echo "=== Pass 1: Find article URL from title ==="
WITH_ARTICLE_URL=$(python3 - <<'PYEOF'
import json
payload = {
    "prompt": "Given the {{title}} find the right url that is talking about this news",
    "jsonSchema": {
        "type": "object",
        "properties": {"article_url": {"type": "string", "description": "The direct article URL"}},
        "required": ["article_url"]
    }
}
print("article_data=deeplineagent:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$SEED" --output "$WORK" --name rss-pass1-article-url $(rows_flag) --with "$WITH_ARTICLE_URL"

echo "=== Pass 2: Extract company name and URL ==="
WITH_COMPANY=$(python3 - <<'PYEOF'
import json
payload = {
    "prompt": "Given the article at {{article_data.article_url}} help me find the company name and company url that raised money. If article_url is empty, use the title: {{title}}",
    "jsonSchema": {
        "type": "object",
        "properties": {
            "company_name": {"type": "string"},
            "company_url": {"type": "string"}
        },
        "required": ["company_name", "company_url"]
    }
}
print("company_details=deeplineagent:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$WORK" --in-place --name rss-pass2-company $(rows_flag) --with "$WITH_COMPANY"

echo "=== Pass 3: Find funding amount and VC ==="
WITH_FUNDING=$(python3 - <<'PYEOF'
import json
payload = {
    "prompt": "Go through {{company_details.company_name}} (website: {{company_details.company_url}}) and find how much money the company raised and from which VC. Use the article at {{article_data.article_url}} as primary source.\n\nReturn:\n> Amount Raised\n> VC",
    "jsonSchema": {
        "type": "object",
        "properties": {
            "funding_amount": {"type": "string"},
            "vc_name": {"type": "string"}
        },
        "required": ["funding_amount", "vc_name"]
    }
}
print("funding_data=deeplineagent:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$WORK" --in-place --name rss-pass3-funding $(rows_flag) --with "$WITH_FUNDING"

echo "=== Pass 4: Find top 5 competitors ==="
WITH_COMPETITORS=$(python3 - <<'PYEOF'
import json
payload = {
    "prompt": "List the top 5 competitors of {{company_details.company_name}} (website: {{company_details.company_url}}). Return only company names, one per line.",
    "jsonSchema": {
        "type": "object",
        "properties": {
            "competitors": {"type": "string", "description": "Top 5 competitor names, newline-separated"}
        },
        "required": ["competitors"]
    }
}
print("competitors_data=deeplineagent:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$WORK" --in-place --name rss-pass4-competitors $(rows_flag) --with "$WITH_COMPETITORS"

echo "=== Pass 5: Enrich company via Crustdata ==="
WITH_CRUSTDATA=$(python3 - <<'PYEOF'
import json
payload = {
    "company_website_domain_list": "{{company_details.company_url}}"
}
print("company_enrich=crustdata_companydb_search:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$WORK" --in-place --name rss-pass5-crustdata $(rows_flag) --with "$WITH_CRUSTDATA"

echo "=== Pass 5b: LeadMagic company fallback ==="
WITH_LEADMAGIC=$(python3 - <<'PYEOF'
import json
payload = {
    "company_name": "{{company_details.company_name}}",
    "domain": "{{company_details.company_url}}"
}
print("leadmagic_enrich=leadmagic_company_enrichment:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$WORK" --in-place --name rss-pass5b-leadmagic $(rows_flag) --with "$WITH_LEADMAGIC"

echo "=== Pass 6: Flatten and filter >50 employees ==="
python3 - "$WORK" "$WORKDIR/companies_qualified.csv" <<'PYEOF'
import csv, json

def get_employee_count(row):
    # Try crustdata first
    enrich = row.get("company_enrich", "")
    if enrich:
        try:
            d = json.loads(enrich) if isinstance(enrich, str) else enrich
            ec = d.get("employeeCount") or d.get("employee_count") or d.get("size", 0)
            return int(str(ec).replace(",", "").split("-")[-1].strip()) if ec else 0
        except Exception:
            pass
    # Try leadmagic fallback
    lm = row.get("leadmagic_enrich", "")
    if lm:
        try:
            d = json.loads(lm) if isinstance(lm, str) else lm
            ec = d.get("employeecount") or d.get("employee_count", 0)
            return int(ec) if ec else 0
        except Exception:
            pass
    return 0

def get_domain(row):
    url = row.get("company_details", {})
    if isinstance(url, str):
        try:
            url = json.loads(url)
        except Exception:
            return ""
    company_url = url.get("company_url", "")
    return company_url.replace("https://", "").replace("http://", "").replace("www.", "").split("/")[0]

with open(sys.argv[1], newline="", encoding="utf-8") as fin, \
     open(sys.argv[2], "w", newline="", encoding="utf-8") as fout:
    reader = csv.DictReader(fin)
    out_fields = ["title", "article_url", "company_name", "company_url", "domain",
                  "funding_amount", "vc_name", "competitors", "industry", "employee_count"]
    writer = csv.DictWriter(fout, fieldnames=out_fields)
    writer.writeheader()
    total, kept = 0, 0
    for row in reader:
        total += 1
        emp = get_employee_count(row)
        if emp < 50:
            continue
        try:
            cd = json.loads(row.get("company_details", "{}")) if isinstance(row.get("company_details"), str) else row.get("company_details", {})
            fd = json.loads(row.get("funding_data", "{}")) if isinstance(row.get("funding_data"), str) else row.get("funding_data", {})
            comp = json.loads(row.get("competitors_data", "{}")) if isinstance(row.get("competitors_data"), str) else row.get("competitors_data", {})
            ad = json.loads(row.get("article_data", "{}")) if isinstance(row.get("article_data"), str) else row.get("article_data", {})
        except Exception:
            cd, fd, comp, ad = {}, {}, {}, {}
        writer.writerow({
            "title": row.get("title", ""),
            "article_url": ad.get("article_url", ""),
            "company_name": cd.get("company_name", ""),
            "company_url": cd.get("company_url", ""),
            "domain": get_domain(row),
            "funding_amount": fd.get("funding_amount", ""),
            "vc_name": fd.get("vc_name", ""),
            "competitors": comp.get("competitors", ""),
            "industry": "",
            "employee_count": emp,
        })
        kept += 1

import sys
print(f"Filtered: {kept}/{total} companies with >50 employees → {sys.argv[2]}")
PYEOF

echo "Done. Run with 'full' to process all rows: ./scripts/02_enrich_companies.sh full"
