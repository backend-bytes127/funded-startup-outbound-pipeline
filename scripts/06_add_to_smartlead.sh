#!/usr/bin/env bash
# Pushes verified contacts with copy to the Smartlead campaign (batches of 400)
set -euo pipefail

set -a; source .env.deepline; set +a
: "${SMARTLEAD_API_KEY:?SMARTLEAD_API_KEY must be set in .env.deepline}"
: "${SMARTLEAD_CAMPAIGN_ID:?SMARTLEAD_CAMPAIGN_ID must be set in .env.deepline}"

WORKDIR="deepline/data"
IN="$WORKDIR/contacts_final.csv"

echo "=== Pushing contacts to Smartlead campaign ${SMARTLEAD_CAMPAIGN_ID} ==="

python3 - "$IN" "$SMARTLEAD_CAMPAIGN_ID" "$SMARTLEAD_API_KEY" <<'PYEOF'
import csv, json, sys, urllib.request, urllib.error

csv_path, campaign_id, api_key = sys.argv[1], sys.argv[2], sys.argv[3]

leads = []
with open(csv_path, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        email = row.get("email", "").strip()
        if not email or not row.get("email_subject", "").strip():
            continue
        lead = {
            "email": email,
            "first_name": row.get("first_name", ""),
            "last_name": row.get("last_name", ""),
            "company_name": row.get("company_name", ""),
            "location": row.get("location", ""),
            "custom_fields": {
                "job_title": row.get("job_title", ""),
                "linkedin_url": row.get("linkedin_url", ""),
                "funding_amount": row.get("funding_amount", ""),
                "vc_name": row.get("vc_name", ""),
                "competitors": row.get("competitors", ""),
                "email_subject": row.get("email_subject", ""),
                "email_body": row.get("email_body", ""),
            }
        }
        leads.append(lead)

print(f"Loaded {len(leads)} leads from CSV")

# Push in batches of 400 (Smartlead limit)
BATCH = 400
pushed, failed = 0, 0
for i in range(0, len(leads), BATCH):
    batch = leads[i:i + BATCH]
    payload = json.dumps({"lead_list": batch}).encode("utf-8")
    url = f"https://server.smartlead.ai/api/v1/campaigns/{campaign_id}/leads?api_key={api_key}"
    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "Mozilla/5.0")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
            ok = result.get("ok", True)
            if ok:
                pushed += len(batch)
                print(f"  Batch {i//BATCH + 1}: pushed {len(batch)} leads ✓")
            else:
                failed += len(batch)
                print(f"  Batch {i//BATCH + 1}: FAILED — {result}")
    except urllib.error.HTTPError as e:
        failed += len(batch)
        print(f"  Batch {i//BATCH + 1}: HTTP {e.code} — {e.read().decode()[:200]}")

print(f"\nDone: {pushed} pushed, {failed} failed")
print(f"View campaign: https://app.smartlead.ai/app/email-campaigns-v2/{campaign_id}/leads")
PYEOF
