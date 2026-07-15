# Funded Startup Outbound Pipeline

A Claude + Deepline rebuild of a Clay pipeline that turns daily funding news into personalized outbound emails in Smartlead — fully automated, no manual work.

---

## What it does

```
Google News RSS  →  AI research  →  People search  →  Email finding  →  AI copywriting  →  Smartlead
(seed rounds,        article URL,    Senior Mktg/Sales/    LeadMagic         personalized        push to
 last 7 days)        company name,   CRO contacts          find + validate   cold email          campaign
                     funding, VC,    (US + Canada;
                     competitors     fallback: deeplineagent)
```

The pipeline runs on [Deepline](https://deepline.com) — a CLI tool that wraps 50+ data providers (Crustdata, LeadMagic, etc.) and AI agents behind a single `deepline enrich` command. Each step is a shell script that reads a CSV, enriches it with one or more tools, and writes the result.

---

## Pipeline overview

| # | Script | Input → Output | What it does |
|---|--------|----------------|--------------|
| 1 | `01_fetch_rss.sh` | Google News RSS → `seed_companies.csv` | Parse funded startup news from last 7 days |
| 2 | `02_enrich_companies.sh` | `seed_companies.csv` → `companies_qualified.csv` | 6-pass AI enrichment: article URL, company name/URL, funding, VC, competitors, headcount |
| 3 | `03_find_people.sh` | `companies_qualified.csv` → `contacts_flat.csv` | Find Senior Marketing / Sales / CRO contacts via Crustdata (fallback: deeplineagent) |
| 4 | `04_find_emails.sh` | `contacts_flat.csv` → `contacts_verified.csv` | Find + validate work emails via LeadMagic |
| 5 | `05_write_copy.sh` | `contacts_verified.csv` → `contacts_final.csv` | Write personalized cold emails with AI (funding context, competitors, role) |
| 6 | `06_add_to_smartlead.sh` | `contacts_final.csv` → Smartlead campaign | Push verified leads with custom email subject/body to campaign |

All intermediate CSVs live in `deepline/data/` (gitignored). Credentials never touch source code.

---

## Setup

### 1. Install Deepline

```bash
npm install -g deepline
deepline auth register --wait auto
deepline auth status
```

> If behind a firewall: `npm install -g deepline --registry https://code.deepline.com/api/v2/npm/`

### 2. Configure credentials

Create `.env.deepline` in the repo root (gitignored — never commit this):

```bash
SMARTLEAD_API_KEY='your-smartlead-api-key'
SMARTLEAD_CAMPAIGN_ID='your-campaign-id'
```

All Deepline tool credentials (Crustdata, LeadMagic, etc.) are managed by Deepline itself after `deepline auth register`. No extra config needed.

### 3. Make scripts executable

```bash
chmod +x scripts/*.sh
```

---

## Usage

### Pilot run — test with 1 row before spending credits

Always do this first to verify the pipeline is working:

```bash
./scripts/01_fetch_rss.sh
./scripts/02_enrich_companies.sh pilot   # enriches row 0 only
./scripts/03_find_people.sh pilot
./scripts/04_find_emails.sh pilot
./scripts/05_write_copy.sh pilot
# Review deepline/data/contacts_final.csv to verify output quality
./scripts/06_add_to_smartlead.sh         # pushes contacts with copy
```

Check your credit balance first: `deepline billing balance`

### Full run — all rows

```bash
./scripts/01_fetch_rss.sh
./scripts/02_enrich_companies.sh full
./scripts/03_find_people.sh full
./scripts/04_find_emails.sh full
./scripts/05_write_copy.sh full
./scripts/06_add_to_smartlead.sh
```

---

## How each step works

### Step 1 — Fetch RSS (`01_fetch_rss.sh`)

Pulls Google News RSS for `"seed round startup"` filtered to the last 7 days. Outputs one row per article: `title`, `link`, `pubdate`.

```
RSS feed: https://news.google.com/rss/search?q=seed+round+startup+when%3A7d
```

### Step 2 — Enrich companies (`02_enrich_companies.sh`)

Six sequential `deepline enrich` passes on each article row:

| Pass | Tool | What it finds |
|------|------|---------------|
| 1 | `deeplineagent` | Article URL from title |
| 2 | `deeplineagent` | Company name + website |
| 3 | `deeplineagent` | Funding amount + lead VC |
| 4 | `deeplineagent` | Top 5 competitors |
| 5 | `crustdata_v3_company_enrich` | Headcount, industry |
| 5b | `leadmagic_company_search` | Headcount fallback |

Filters out companies with <50 employees (too small for outbound).

### Step 3 — Find people (`03_find_people.sh`)

Searches for Senior Marketing, Sales, and CRO titles at each company using `crustdata_v2_people_search_realtime`. For brand-new startups not yet in Crustdata, falls back to `deeplineagent` web search.

Target titles: VP Marketing, VP Sales, CRO, CMO, Head of Marketing, Head of Sales, Director of Marketing/Sales.

Regions: United States, Canada (configurable).

### Step 4 — Find emails (`04_find_emails.sh`)

Two-pass email waterfall:
1. `leadmagic_email_finder` — finds work email from name + domain
2. `leadmagic_email_validation` — validates deliverability

Keeps only contacts with status: `valid`, `valid_catch_all`, or `catch_all`.

### Step 5 — Write copy (`05_write_copy.sh`)

Generates a personalized cold email per contact using `deeplineagent`. The prompt injects:
- First name, job title, company
- Funding amount + VC name (shows research)
- Competitors (signals competitive awareness)
- Employee count (tailors message to growth stage)

Output: `email_subject` + `email_body` (<120 words, peer tone, single CTA for 15-min call).

See `prompts/` for the full prompt templates.

### Step 6 — Push to Smartlead (`06_add_to_smartlead.sh`)

Pushes leads to the configured Smartlead campaign via REST API. Skips contacts without a generated email subject. Batches at 400 leads/request (Smartlead's API limit). Subject and body are stored as custom fields so Smartlead sequences can reference them.

---

## Clay → Deepline mapping

| Clay action | Deepline equivalent |
|------------|---------------------|
| RSS Feed source | `01_fetch_rss.sh` (Google News RSS) |
| `Claygent` find article | `deeplineagent` with JSON schema |
| `Claygent` extract company | `deeplineagent` with JSON schema |
| `Claygent` funding/VC | `deeplineagent` with JSON schema |
| `Claygent` competitors | `deeplineagent` with JSON schema |
| Mixrank company enrich | `crustdata_v3_company_enrich` |
| LeadMagic company enrich | `leadmagic_company_search` |
| Clay "Find People" | `crustdata_v2_people_search_realtime` |
| LeadMagic email finder | `leadmagic_email_finder` |
| LeadMagic email validate | `leadmagic_email_validation` |
| Add to Smartlead campaign | `smartlead_push_to_campaign` (script 06) |

---

## File structure

```
funded-startup-outbound-pipeline/
├── scripts/
│   ├── 01_fetch_rss.sh          # RSS → seed_companies.csv
│   ├── 02_enrich_companies.sh   # company research + enrichment
│   ├── 03_find_people.sh        # contact discovery
│   ├── 04_find_emails.sh        # email finding + validation
│   ├── 05_write_copy.sh         # AI copywriting
│   └── 06_add_to_smartlead.sh  # push to Smartlead
├── prompts/                     # AI prompt templates
├── deepline/
│   └── data/                    # intermediate CSVs (gitignored)
├── .env.deepline                # credentials (gitignored)
└── .gitignore
```

---

## Notes & gotchas

- **New startups**: Brand-new companies (raised seed this week) may not be in Crustdata yet — the pipeline falls back to `deeplineagent` web search automatically
- **Cloudflare**: Smartlead's API is behind Cloudflare — the push script sets `User-Agent: Mozilla/5.0` to avoid 403s
- **Credits**: Each full run costs ~$5–15 in Deepline credits. Check balance with `deepline billing balance`
- **Retry safety**: Re-running a `deepline enrich` play with the same `--name` reuses completed cells, so failed runs can be retried cheaply
- **Pilot mode**: `--rows 0:0` = row 0 only. Always pilot before a full run
- **Data lineage**: Every CSV in `deepline/data/` is a checkpoint — if a step fails, fix and re-run from that step only
