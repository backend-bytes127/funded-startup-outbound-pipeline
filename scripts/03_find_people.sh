#!/usr/bin/env bash
# Finds Senior Marketing, Sales, and CRO contacts at enriched companies (US + Canada)
set -euo pipefail

set -a; source .env.deepline; set +a

WORKDIR="deepline/data"
IN="$WORKDIR/companies_qualified.csv"
OUT="$WORKDIR/contacts_raw.csv"
MODE="${1:-pilot}"

rows_flag() {
  [ "$MODE" = "full" ] && echo "" || echo "--rows 0:1"
}

echo "=== Find people: Senior Marketing / Sales / CRO at each company (US + Canada) ==="
WITH_PEOPLE=$(python3 - <<'PYEOF'
import json
# Crustdata realtime people search — primary
payload = {
    "filters": {
        "company_domain_list": ["{{domain}}"],
        "title_keywords": [
            "Marketing", "Sales", "Revenue", "CRO", "Chief Revenue",
            "VP Marketing", "VP Sales", "Head of Marketing", "Head of Sales"
        ],
        "seniority": ["C-Suite", "VP", "Director", "Head", "Senior"],
        "country": ["United States", "Canada"]
    },
    "limit": 5
}
print("people_results=crustdata_v2_people_search_realtime:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$IN" --output "$OUT" --name find-people $(rows_flag) --with "$WITH_PEOPLE"

echo "=== Flatten people results: one row per contact ==="
python3 - "$OUT" "$WORKDIR/contacts_flat.csv" <<'PYEOF'
import csv, json, sys

with open(sys.argv[1], newline="", encoding="utf-8") as fin:
    reader = csv.DictReader(fin)
    company_rows = list(reader)

out_fields = [
    "first_name", "last_name", "full_name", "job_title", "linkedin_url",
    "company_name", "company_url", "domain", "location",
    "funding_amount", "vc_name", "competitors", "industry", "employee_count"
]

with open(sys.argv[2], "w", newline="", encoding="utf-8") as fout:
    writer = csv.DictWriter(fout, fieldnames=out_fields)
    writer.writeheader()
    total = 0
    for row in company_rows:
        raw = row.get("people_results", "")
        try:
            results = json.loads(raw) if isinstance(raw, str) else raw
            people = results if isinstance(results, list) else results.get("profiles", results.get("results", results.get("data", [])))
        except Exception:
            people = []
        for person in people:
            if not person:
                continue
            fname = person.get("first_name", "") or ""
            lname = person.get("last_name", "") or ""
            writer.writerow({
                "first_name": fname,
                "last_name": lname,
                "full_name": person.get("full_name") or f"{fname} {lname}".strip(),
                "job_title": person.get("title") or person.get("job_title", ""),
                "linkedin_url": person.get("linkedin_url") or person.get("url", ""),
                "company_name": row.get("company_name", ""),
                "company_url": row.get("company_url", ""),
                "domain": row.get("domain", ""),
                "location": person.get("location") or person.get("location_name", ""),
                "funding_amount": row.get("funding_amount", ""),
                "vc_name": row.get("vc_name", ""),
                "competitors": row.get("competitors", ""),
                "industry": row.get("industry", ""),
                "employee_count": row.get("employee_count", ""),
            })
            total += 1

print(f"Flattened {total} contacts → {sys.argv[2]}")
PYEOF

echo "Done. Run with 'full' to process all companies: ./scripts/03_find_people.sh full"
