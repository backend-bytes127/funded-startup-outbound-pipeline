# Funded Startup Outbound Pipeline

A Claude + Deepline rebuild of the Clay pipeline that turns daily funding news into personalized outbound emails in Smartlead.

## What it does

```
Google News RSS (seed round startups, last 7 days)
  → AI research: article URL, company name/URL, funding details, VC, competitors
  → Company filter: >50 employees
  → People search: Senior Marketing / Sales / CRO contacts in US + Canada
  → Email waterfall: LeadMagic → validate
  → AI copywriting: personalized cold email per contact
  → Smartlead: push to campaign
```

## Pipeline scripts

| Script | Input | Output | What it does |
|--------|-------|--------|--------------|
| `01_fetch_rss.sh` | Google News RSS | `seed_companies.csv` | Fetch funded startup news (daily) |
| `02_enrich_companies.sh` | `seed_companies.csv` | `companies_qualified.csv` | AI research + company enrichment, filter >50 emp |
| `03_find_people.sh` | `companies_qualified.csv` | `contacts_flat.csv` | Find Senior Marketing/Sales/CRO in US+Canada |
| `04_find_emails.sh` | `contacts_flat.csv` | `contacts_verified.csv` | Find + validate work emails |
| `05_write_copy.sh` | `contacts_verified.csv` | `contacts_final.csv` | Write personalized cold emails |
| `06_add_to_smartlead.sh` | `contacts_final.csv` | Smartlead campaign | Push leads to campaign |

## Setup

### 1. Install Deepline

```bash
npm install -g deepline
deepline auth register --wait auto
deepline auth status
```

### 2. Configure credentials

```bash
cp .env.deepline.example .env.deepline
# Fill in DEEPLINE_API_KEY, SMARTLEAD_API_KEY, SMARTLEAD_CAMPAIGN_ID
```

### 3. Make scripts executable

```bash
chmod +x scripts/*.sh
```

## Usage

### Pilot run (one row, free — verify output before spending credits)

```bash
./scripts/01_fetch_rss.sh
./scripts/02_enrich_companies.sh pilot
./scripts/03_find_people.sh pilot
./scripts/04_find_emails.sh pilot
./scripts/05_write_copy.sh pilot
# Review deepline/data/contacts_final.csv — then:
./scripts/06_add_to_smartlead.sh
```

### Full run

```bash
./scripts/01_fetch_rss.sh
./scripts/02_enrich_companies.sh full
./scripts/03_find_people.sh full
./scripts/04_find_emails.sh full
./scripts/05_write_copy.sh full
./scripts/06_add_to_smartlead.sh
```

## Clay → Deepline mapping

| Clay action | Deepline equivalent |
|------------|---------------------|
| RSS Feed Source | `01_fetch_rss.sh` (Google News RSS parser) |
| `use-ai (claygent)` article URL | `deeplineagent` with Exa web search |
| `use-ai (claygent)` company extract | `deeplineagent` + JSON schema |
| `use-ai (claygent)` funding/VC | `deeplineagent` + JSON schema |
| `use-ai (claygent)` competitors | `deeplineagent` + JSON schema |
| `enrich-company-with-mixrank-v2` | `crustdata_companydb_search` |
| `leadmagic-enrich-company` | `leadmagic_company_enrichment` |
| `trigger-find-people-source` | `crustdata_v2_people_search_realtime` |
| `leadmagic-find-work-email` | `leadmagic_email_finder` |
| `leadmagic-validate-email` | `leadmagic_email_validation` |
| `add-lead-to-campaign` (Smartlead) | `smartlead_push_to_campaign` |

## Prompts

All AI prompts are in `prompts/` — edit them to customize research angles or email copy.

## Notes

- All output CSVs and credentials are gitignored
- Run `deepline billing balance` to check credits before a full run
- Pilot mode (`--rows 0:1`) verifies the pipeline works before spending credits
- Smartlead push is batched at 400 leads/request (API limit)
