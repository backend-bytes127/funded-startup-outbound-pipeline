#!/usr/bin/env bash
# Writes personalized cold emails for each verified contact using their company context
set -euo pipefail

set -a; source .env.deepline; set +a

WORKDIR="deepline/data"
IN="$WORKDIR/contacts_verified.csv"
OUT="$WORKDIR/contacts_with_copy.csv"
MODE="${1:-pilot}"

rows_flag() {
  [ "$MODE" = "full" ] && echo "" || echo "--rows 0:1"
}

echo "=== Write personalized cold email for each contact ==="
WITH_COPY=$(python3 - <<'PYEOF'
import json

prompt = """Write a short, personalized cold email for {{first_name}} {{last_name}}, {{job_title}} at {{company_name}}.

Context about their company:
- Recently raised {{funding_amount}} from {{vc_name}}
- Top competitors: {{competitors}}
- Employee count: {{employee_count}}

Guidelines:
- Under 120 words
- First line references their recent funding round (shows research)
- Second paragraph: one clear value prop relevant to their role and growth stage
- Single CTA: ask for a 15-min call this week
- No generic openers like "I hope this email finds you well"
- Sound like a peer, not a vendor

Return the email as plain text. First line must be: Subject: <your subject line>"""

payload = {
    "prompt": prompt,
    "jsonSchema": {
        "type": "object",
        "properties": {
            "subject": {"type": "string"},
            "email_body": {"type": "string", "description": "Email body only, no subject line"}
        },
        "required": ["subject", "email_body"]
    }
}
print("copy_result=deeplineagent:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$IN" --output "$OUT" --name write-copy $(rows_flag) --with "$WITH_COPY"

echo "=== Flatten copy into final CSV ==="
python3 - "$OUT" "$WORKDIR/contacts_final.csv" <<'PYEOF'
import csv, json, sys

with open(sys.argv[1], newline="", encoding="utf-8") as fin, \
     open(sys.argv[2], "w", newline="", encoding="utf-8") as fout:
    reader = csv.DictReader(fin)
    out_fields = [
        "first_name", "last_name", "full_name", "email", "email_status",
        "job_title", "linkedin_url", "company_name", "domain", "location",
        "funding_amount", "vc_name", "competitors", "employee_count",
        "email_subject", "email_body"
    ]
    writer = csv.DictWriter(fout, fieldnames=out_fields)
    writer.writeheader()
    count = 0
    for row in reader:
        try:
            copy = json.loads(row.get("copy_result", "{}")) if isinstance(row.get("copy_result"), str) else row.get("copy_result", {})
        except Exception:
            copy = {}
        writer.writerow({
            "first_name": row.get("first_name", ""),
            "last_name": row.get("last_name", ""),
            "full_name": row.get("full_name", ""),
            "email": row.get("email", ""),
            "email_status": row.get("email_status", ""),
            "job_title": row.get("job_title", ""),
            "linkedin_url": row.get("linkedin_url", ""),
            "company_name": row.get("company_name", ""),
            "domain": row.get("domain", ""),
            "location": row.get("location", ""),
            "funding_amount": row.get("funding_amount", ""),
            "vc_name": row.get("vc_name", ""),
            "competitors": row.get("competitors", ""),
            "employee_count": row.get("employee_count", ""),
            "email_subject": copy.get("subject", ""),
            "email_body": copy.get("email_body", ""),
        })
        count += 1

print(f"Final CSV with copy: {count} contacts → {sys.argv[2]}")
PYEOF

echo "Done. Run with 'full' to generate copy for all: ./scripts/05_write_copy.sh full"
