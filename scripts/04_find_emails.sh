#!/usr/bin/env bash
# Finds and validates work emails for each contact via LeadMagic waterfall
set -euo pipefail

set -a; source .env.deepline; set +a

WORKDIR="deepline/data"
IN="$WORKDIR/contacts_flat.csv"
OUT="$WORKDIR/contacts_with_email.csv"
MODE="${1:-pilot}"

rows_flag() {
  [ "$MODE" = "full" ] && echo "" || echo "--rows 0:1"
}

echo "=== Pass 1: Find work email via LeadMagic ==="
WITH_EMAIL=$(python3 - <<'PYEOF'
import json
payload = {
    "name": "{{full_name}}",
    "domain": "{{domain}}"
}
print("email_result=leadmagic_email_finder:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$IN" --output "$OUT" --name find-emails $(rows_flag) --with "$WITH_EMAIL"

echo "=== Pass 2: Validate email ==="
WITH_VALIDATE=$(python3 - <<'PYEOF'
import json
payload = {
    "email": "{{email_result.email}}",
    "onlySafe": True
}
print("email_validation=leadmagic_email_validation:" + json.dumps(payload))
PYEOF
)
deepline enrich --input "$OUT" --in-place --name validate-emails $(rows_flag) --with "$WITH_VALIDATE"

echo "=== Pass 3: Filter to valid emails only ==="
python3 - "$OUT" "$WORKDIR/contacts_verified.csv" <<'PYEOF'
import csv, json, sys

VALID_STATUSES = {"valid", "valid_catch_all", "catch_all"}

with open(sys.argv[1], newline="", encoding="utf-8") as fin, \
     open(sys.argv[2], "w", newline="", encoding="utf-8") as fout:
    reader = csv.DictReader(fin)
    fields = reader.fieldnames + ["email", "email_status"]
    writer = csv.DictWriter(fout, fieldnames=fields)
    writer.writeheader()
    total, kept = 0, 0
    for row in reader:
        total += 1
        try:
            er = json.loads(row.get("email_result", "{}")) if isinstance(row.get("email_result"), str) else row.get("email_result", {})
            ev = json.loads(row.get("email_validation", "{}")) if isinstance(row.get("email_validation"), str) else row.get("email_validation", {})
        except Exception:
            er, ev = {}, {}
        email = er.get("email", "")
        status = ev.get("status", ev.get("result", ""))
        if not email or status.lower() not in VALID_STATUSES:
            continue
        row["email"] = email
        row["email_status"] = status
        writer.writerow(row)
        kept += 1
    print(f"Verified: {kept}/{total} contacts with valid emails → {sys.argv[2]}")
PYEOF

echo "Done. Run with 'full' to process all contacts: ./scripts/04_find_emails.sh full"
