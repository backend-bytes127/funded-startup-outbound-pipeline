#!/usr/bin/env bash
# Fetches Google News RSS for funded startups (last 7 days) → seed_companies.csv
set -euo pipefail

WORKDIR="deepline/data"
mkdir -p "$WORKDIR"
OUT="$WORKDIR/seed_companies.csv"
RSS_URL="https://news.google.com/rss/search?q=seed+round+startup+when%3A7d&hl=en-US&gl=US&ceid=US%3Aen"

python3 - "$RSS_URL" "$OUT" <<'PYEOF'
import sys, csv, urllib.request
from xml.etree import ElementTree as ET

url, out = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=30) as r:
    content = r.read()

root = ET.fromstring(content)
channel = root.find("channel")
items = channel.findall("item")

with open(out, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=["guid", "title", "pub_date"])
    writer.writeheader()
    for item in items:
        guid = (item.findtext("guid") or "").strip()
        title = (item.findtext("title") or "").strip()
        pub_date = (item.findtext("pubDate") or "").strip()
        if title:
            writer.writerow({"guid": guid, "title": title, "pub_date": pub_date})

print(f"Fetched {len(items)} RSS items → {out}")
PYEOF
