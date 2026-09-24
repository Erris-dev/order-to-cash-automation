# Setup

> All 16 workflows are built and tested end to end with real Twenty, Odoo, Gmail and OpenRouter
> accounts, and import cleanly into a fresh n8n. Troubleshooting: [RUNBOOK.md](RUNBOOK.md).

**Order of work:** start the stack (§2) → first logins and API keys (§3) → credentials (§4) →
import (§5) → run WF-05a and WF-00 once (§5) → test (§5a).

## 1. Prerequisites

| Tool | Version tested | Notes |
|---|---|---|
| Docker Desktop / Engine | 29.4 | ≥ 6 GB RAM for Docker (Odoo + n8n + Postgres) |
| Docker Compose | v5.1 | plugin syntax `docker compose` |
| Bash | Git Bash on Windows, or any Linux/macOS shell | for `scripts/*.sh` |
| `openssl` | any | used by `generate-env.sh` / `send-test-lead.sh` (bundled with Git Bash) |

Pinned images (see `docker-compose.yml`):

| Service | Image |
|---|---|
| n8n main + worker | `docker.n8n.io/n8nio/n8n:2.41.4` |
| Task runners (Code node sandbox) | `n8nio/runners:2.41.4` (must match n8n) |
| Postgres 17 + pgvector | `pgvector/pgvector:0.8.6-pg17-bookworm` |
| Redis | `redis:8.10.2` |
| Odoo Community | `odoo:19.0-20260926` |
| Twenty CRM (server + worker) | `twentycrm/twenty:v2.43.0` |

## 2. Start the stack

```bash
./scripts/generate-env.sh      # creates .env with random secrets
# edit .env: set ALERT_EMAIL_TO (your inbox for alerts/reports)
docker compose up -d
docker compose ps              # odoo-init shows "Exited (0)" – that is expected
```

First start takes 2–3 minutes: `odoo-init` installs the Odoo modules
(Contacts, Sales, Invoicing, German localisation) into the `odoo` database and
runs `db/odoo-setup.py`, which turns the default company into **Muster GmbH**
(Hamburg, EUR, SKR03 chart of accounts, EUR pricelist) and creates the product
`CRM-DEAL` used by WF-03. Both steps are idempotent and run on every
`docker compose up`. Meanwhile Twenty runs its
database migrations. Later starts skip both. On the first start Twenty logs a few
`relation "core…" does not exist` errors before its migrations run. They are harmless.

| URL | What |
|---|---|
| http://localhost:5678 | n8n editor |
| http://localhost:8069 | Odoo |
| http://localhost:3000 | Twenty CRM |
| `localhost:5434` | Postgres (host access only, bound to 127.0.0.1) |

Health checks:

```bash
curl http://localhost:5678/healthz/readiness                                   # {"status":"ok"}
docker compose exec -T n8n-worker wget -qO- http://localhost:5678/healthz/readiness
curl http://localhost:3000/healthz                                             # {"status":"ok",…}
docker compose exec -T postgres psql -U postgres -d automation -c '\dt'        # 7 project tables
```

### How the containers fit together

- **n8n-main** serves the editor, receives webhooks and fires schedules. It
  does **not** execute workflows (`EXECUTIONS_MODE=queue`); it pushes them into
  Redis. Manual test runs are also offloaded (`OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`).
- **n8n-worker** pulls executions from Redis and runs them.
- **n8n-runners** / **n8n-runners-main** are the task-runner sidecars of the worker
  and the main instance: Code node JavaScript runs there, isolated from n8n's
  process and credentials (external runner mode). The main instance needs its own
  runner for CLI runs (`n8n execute`).
  `config/n8n-task-runners.json` allowlists the `crypto` builtin
  (`NODE_FUNCTION_ALLOW_BUILTIN=crypto`).
- Binary data (email attachments, PDFs) is stored in Postgres
  (`N8N_DEFAULT_BINARY_DATA_MODE=database`), because filesystem mode doesn't work
  when main and worker are separate containers.
- **Postgres** hosts four databases, each with its own role: `n8n`, `automation`
  (project tables, `db/init.sql`), `odoo` and `twenty`.
- **Redis** holds n8n's queue in DB 0 and Twenty's job queue in DB 1.
- **twenty-server / twenty-worker** make up the CRM. n8n talks to it at
  `http://twenty-server:3000` (REST API); Twenty calls n8n back through webhooks.

## 3. First login

### n8n
1. Open http://localhost:5678 and create the owner account.

### Odoo
1. Open http://localhost:8069 and log in with **admin / admin**.
2. **Change the admin password immediately** (avatar → *My Profile* → *Security*).
3. Create an API key for n8n: avatar → *My Profile* → *Security* →
   *New API Key*, name it `n8n`. Copy it; Odoo shows it only once.

The database manager is disabled (`--no-database-list`), and Odoo only serves the
`odoo` database.

### Twenty
1. Open http://localhost:3000 and sign up with email + password. This creates a
   local account on your own instance; nothing is sent anywhere and no email
   verification is needed.
2. Create the workspace (name it `Muster GmbH`). This first account becomes the
   admin. After that, nobody can create another workspace, and new users can only
   join by invitation.
   Twenty adds **sample records** (Stripe, Notion, Figma, …; one sample opportunity is already
   at stage *Customer*). Delete them (select all → *Delete*) so the reconciliation doesn't create
   Odoo orders for them.
3. Create an API key for n8n: *Settings → APIs & Webhooks* (you may need to
   switch on *Advanced mode* at the bottom of the settings menu) →
   *Create API key*, name `n8n`. Copy it; Twenty shows it only once.

## 4. Credentials to create in n8n

The workflow JSON files refer to credentials **by name**. Create them in n8n
(*Overview → Credentials → Create*) with **exactly** these names, then import
the workflows. If a name doesn't match, n8n shows the node as having no credential.

| Credential name | n8n credential type | Values | Used by | Status |
|---|---|---|---|---|
| `Postgres – Automation` | Postgres | Host `postgres`, DB `automation`, user `automation`, password = `AUTOMATION_DB_PASSWORD` from `.env`, port `5432`, SSL disabled | all workflows | final |
| `Twenty – Muster` | Bearer Auth | Bearer Token = Twenty API key; *Allowed domains*: `twenty-server` | WF-00, WF-01, WF-03, WF-06 | final |
| `Odoo – Muster` | Odoo API (API Key) | Site URL `http://odoo:8069`, Database `odoo`, API key from section 3; *Allowed domains*: `odoo` | WF-03, WF-04b, WF-05c, WF-06 | final |
| `Gmail – Muster` | Gmail OAuth2 API | Google Cloud OAuth client (see below) | WF-04 (trigger), WF-10 (all outgoing mail) | final |
| `OpenRouter – Muster` | OpenRouter | OpenRouter API key | WF-02, WF-04, WF-05, WF-05a, WF-05b | final |

The names use an en dash (`–`), not a hyphen. Copy them from this table.

Instead of typing the Postgres credential, you can import it from `.env`
(the password never leaves your machine):

```bash
pw=$(grep '^AUTOMATION_DB_PASSWORD=' .env | cut -d= -f2)
printf '[{"id":"o2cPgAutomation1","name":"Postgres – Automation","type":"postgres","data":{"host":"postgres","database":"automation","user":"automation","password":"%s","port":5432,"ssl":"disable","allowUnauthorizedCerts":false,"sshTunnel":false}}]' "$pw" \
  | docker compose exec -T n8n-main sh -c 'cat > /tmp/c.json && n8n import:credentials --input=/tmp/c.json; rm -f /tmp/c.json'
```

**Odoo:** the workflows call Odoo 19's JSON-2 API (`POST /json/2/<model>/<method>`)
through HTTP Request nodes that use this credential. The credential's notice about a
"Custom pricing plan" applies only to Odoo Online; self-hosted Community is not affected.
Inside Docker the URL is `http://odoo:8069`, not `localhost`.

**Twenty:** n8n has no Twenty node, so the workflows call Twenty's REST API
(`http://twenty-server:3000/rest/...`) through HTTP Request nodes that use this
Bearer credential.

### Gmail OAuth2
1. Google Cloud Console → new project (or reuse one) → *APIs & Services → Library* →
   enable **Gmail API**.
2. *Google Auth Platform* (OAuth consent screen) → External → add yourself under
   *Audience → Test users*. Then **Publish app**: in *Testing* mode, refresh tokens
   expire after 7 days and mail stops working.
3. *Clients → Create client → Web application*, redirect URI
   `http://localhost:5678/rest/oauth2-credential/callback`.
4. n8n → credential **Gmail OAuth2 API**, name `Gmail – Muster` (n8n suggests
   "Gmail account", so rename it), paste client ID + secret → *Sign in with Google*.
5. Set `ALERT_EMAIL_TO` in `.env`, run `docker compose up -d` and
   `./scripts/import-workflows.sh` again so WF-04 and WF-10 pick up the credential.

## 5. Import the workflows

```bash
./scripts/import-workflows.sh
```

What the script does:

1. Imports every `workflows/*.json`. Each file has a fixed `id`, so re-importing
   overwrites instead of duplicating, and `settings.errorWorkflow` keeps pointing
   at WF-07. Credentials are referenced as `{ "id": null, "name": "…" }`; n8n
   resolves them **by name and type** on import.
2. Publishes the workflows marked `"active": true` (WF-01, 02, 03, 07, 10).
   WF-07 and WF-10 are published explicitly, because n8n's activation check
   rejects them until `Gmail – Muster` exists, and error logging must work without mail.
3. Restarts `n8n-main`, which only registers CLI-published webhooks on startup.

If you create a credential **after** importing, run the script again so the nodes
pick it up (or select the credential in each node).

### Load the chatbot knowledge base (WF-05a)

`knowledge-base/` is mounted read-only at `/knowledge-base` (the only folder n8n's file nodes
may read: `N8N_RESTRICT_FILE_ACCESS_TO`). Load it once, and again after editing a file:

```bash
docker compose exec -T n8n-main n8n execute --id=o2cWf05aKbIngest
```

Expect 12 files → 34 chunks in `kb_chunks` (DE + EN). Re-running replaces chunks per file and
never duplicates them.

### Run WF-00 once

Open **WF-00 Setup Twenty** in n8n and click **Execute workflow** (or run
`docker compose exec -T n8n-main n8n execute --id=o2cWf00SetupTwnt`). It

- adds the custom field **ERP Order Ref** to Twenty opportunities, and
- registers the Twenty → n8n webhook for `opportunity.updated`, signed with
  `TWENTY_WEBHOOK_SECRET`.

Running it again is safe: it only fixes what is missing.

| Workflow | ID | Trigger | Active |
|---|---|---|---|
| WF-00 Setup Twenty | `o2cWf00SetupTwnt` | manual | no (run once) |
| WF-01 Lead Intake | `o2cWf01LeadIntak` | `POST /webhook/lead-intake` | yes |
| WF-02 AI Lead Qualification | `o2cWf02LeadScore` | called by WF-01 | yes |
| WF-03 Deal Won to ERP | `o2cWf03DealToErp` | `POST /webhook/twenty-opportunity` (from Twenty) | yes |
| WF-04 Document Processing | `o2cWf04DocProcss` | Gmail poll (`INVOICE_MAIL_QUERY`) + `POST /webhook/invoice-upload` | yes |
| WF-04b Book Vendor Bill | `o2cWf04bBookBill` | called by WF-04 and WF-09 | yes |
| WF-05 Support Chatbot | `o2cWf05SupportBt` | n8n hosted chat (public) | yes |
| WF-05a KB Ingestion | `o2cWf05aKbIngest` | manual (after editing `knowledge-base/`) | no |
| WF-05b KB Search | `o2cWf05bKbSearch` | agent tool | yes |
| WF-05c Order Status Lookup | `o2cWf05cOrderSts` | agent tool | yes |
| WF-05d Escalate to Human | `o2cWf05dEscalate` | agent tool | yes |
| WF-06 CRM-ERP Reconciliation | `o2cWf06Reconcile` | daily 02:00 (+ manual) | yes |
| WF-07 Error Handler | `o2cWf07ErrorsHdl` | error trigger | yes |
| WF-08 Daily Health Report | `o2cWf08HealthRpt` | daily 08:00 (+ manual) | yes |
| WF-09 Review Decision | `o2cWf09ReviewDec` | `GET` / `POST /webhook/review-decision` (links in emails) | yes |
| WF-10 Send Notification | `o2cWf10SendNotif` | called by other workflows | yes |

To export changes made in the UI: `./scripts/export-workflows.sh` writes to
`workflows/_export/` (git-ignored). Review, then copy into `workflows/`.

## 5a. Test the core flow

```bash
./scripts/send-test-lead.sh test-payloads/lead-de-valid.json                   # 202, new lead
./scripts/send-test-lead.sh test-payloads/lead-de-valid.json                   # 202, "duplicate": true
./scripts/send-test-lead.sh test-payloads/lead-en-valid.json                   # 202, English lead
./scripts/send-test-lead.sh test-payloads/lead-freemail-no-website.json        # 202, company matched by name
./scripts/send-test-lead.sh test-payloads/lead-invalid.json                    # 422 + list of problems
./scripts/send-test-lead.sh test-payloads/lead-de-valid.json --bad-signature   # 401
./scripts/send-test-lead.sh test-payloads/lead-de-valid.json --stale           # 401 (replay window)
```

Then in Twenty open *Opportunities* and drag **Hotel Alpenblick GmbH – website inquiry**
to stage **Customer**. Within seconds:

- Odoo → *Sales* shows a confirmed order (`S0000x`) for Hotel Alpenblick GmbH,
  €48,000 + 19 % VAT;
- the opportunity's **ERP Order Ref** field shows the order number;
- `sync_map` has the customer and order rows.

Moving it away and back to Customer does **not** create a second order.

Check the database:

```bash
docker compose exec -T postgres psql -U postgres -d automation -c "select id, email, status, crm_opportunity_id from leads; select * from sync_map; select event_type, message from event_log order by id;"
```

### AI lead scoring (WF-02)

Every lead from 5a is scored automatically. See the `ai_*` columns in `leads` and
the **Lead Score** / **Lead Score Reason** fields in Twenty. Scores ≥ `HOT_LEAD_THRESHOLD`
send a "Heißer Lead / Hot lead" email.
`test-payloads/lead-prompt-injection.json` tries to talk the model into a score of 100;
it should come back near 0 as spam.

### Document processing (WF-04)

```bash
./scripts/upload-document.sh sample-documents/*.pdf
docker compose exec -T postgres psql -U postgres -d automation -c \
  "select id, file_name, status, invoice_number, total_amount, confidence, validation_errors from documents order by id;"
```

| File | Expected result |
|---|---|
| `01-invoice-ok-paper-19pct.pdf` | **booked**: vendor bill posted in Odoo (*Invoicing → Vendors → Bills*) with the PDF attached |
| `02-invoice-ok-coffee-7pct-en.pdf` | **booked** (7 % VAT, English layout) |
| `03-invoice-wrong-total.pdf` | **needs_review**: net + VAT ≠ total |
| `04-invoice-blurry-scan.pdf` | **needs_review**: poor legibility, numbers don't add up |
| `05-delivery-note-not-an-invoice.pdf` | **rejected**: not an invoice |
| `06-invoice-ok-paper-reorder.pdf` | **booked**; vendor matched by VAT ID, not created again |

Uploading a regenerated copy of an already-booked invoice lands in **needs_review**
("possible duplicate"). Uploading the identical file again is skipped (same SHA-256).
Regenerate the PDFs with the command at the top of `sample-documents/generate_invoices.py`.

**By email:** send a PDF to the address in `INVOICE_MAIL_QUERY` (e.g.
`you+invoices@gmail.com`). WF-04 polls Gmail every minute.

### Support chatbot (WF-05)

Open the chat: in n8n, open **WF-05 Support Chatbot** → node *When Chat Message Received* →
copy the **Chat URL** (`http://localhost:5678/webhook/1508b34f-8bd7-4e0e-a4f4-21f5277dc8bf/chat`
with the shipped workflow). Try:

| Message | Expected |
|---|---|
| *Wie hoch ist der Mindestbestellwert?* | German answer from the KB: 500 € net, free delivery from 750 € |
| *Can I pay by credit card?* | English answer: no; payment options listed |
| *What's the status of my order S00002?* → then the customer's email | asks for the email, then: confirmed, 57,120.00 EUR, not invoiced yet |
| same order with a different email | "no order found", with no detail leaked |
| *Bei der Lieferung waren Kartons zerdrückt …* → email | ticket in `review_queue` (`support_request`) + email to `ALERT_EMAIL_TO`; reply contains the ticket number |
| a price question | no invented price; offers to forward to a colleague |

The chat can also be driven by API, which is useful for tests:

```bash
curl -s -X POST http://localhost:5678/webhook/1508b34f-8bd7-4e0e-a4f4-21f5277dc8bf/chat \
  -H 'content-type: application/json' \
  -d '{"action":"sendMessage","sessionId":"test-1","chatInput":"Wie lange dauert die Lieferung nach Wien?"}'
```

### Review decisions (WF-09)

Every review email (invoice, chat ticket, reconciliation issue) has **Approve / Reject** links.
A link opens a confirmation page; only the button there changes anything. Each link works once.
Approving an invoice creates a **draft** vendor bill in Odoo (with the PDF) for the accountant to post.

### Reconciliation (WF-06) and health report (WF-08)

Both run on a schedule, and you can start them any time with *Execute workflow* in n8n, or:

```bash
docker compose exec -T n8n-main n8n execute --id=o2cWf06Reconcile
docker compose exec -T n8n-main n8n execute --id=o2cWf08HealthRpt
```

To see the reconciliation work, create a mismatch in Twenty: clear an opportunity's **ERP Order Ref**
(→ fixed automatically) or change its **amount** (→ reported, with links). A won opportunity whose
webhook never arrived is replayed to WF-03, which creates the missing order.

**Forced error:** `docker compose stop twenty-server`, send a lead, wait about 20 s
(3 retries), then `docker compose start twenty-server`. The failure appears in
`workflow_errors` with the node name and an execution link.
`test-payloads/twenty-opportunity-won.example.json` shows what Twenty sends to WF-03.

## 6. Configuration (`.env`)

| Variable | Purpose |
|---|---|
| `POSTGRES_PASSWORD`, `N8N_DB_PASSWORD`, `AUTOMATION_DB_PASSWORD`, `ODOO_DB_PASSWORD`, `TWENTY_DB_PASSWORD` | DB roles. Applied only when the Postgres volume is **first created**. |
| `N8N_ENCRYPTION_KEY` | Encrypts n8n credentials; shared by main and worker. Keep a backup. |
| `N8N_RUNNERS_AUTH_TOKEN` | Worker ↔ task-runner shared secret |
| `N8N_PUBLIC_URL` | Base URL for webhooks and links in emails |
| `LEAD_WEBHOOK_HMAC_SECRET` | Shared secret the website uses to sign lead POSTs (WF-01) |
| `TWENTY_WEBHOOK_SECRET` | Twenty signs its webhook calls to WF-03 with it; WF-00 registers it in Twenty |
| `INVOICE_MAIL_QUERY` | Gmail search for invoice mails (WF-04). Keep it narrow: every matching PDF is sent to the LLM |
| `DOC_UPLOAD_TOKEN` | Token for `POST /webhook/invoice-upload` (`scripts/upload-document.sh`) |
| `TWENTY_PUBLIC_URL` | Twenty URL used in links inside emails (default `http://localhost:3000`) |
| `LLM_BASE_URL`, `LLM_MODEL`, `LLM_VISION_MODEL`, `LLM_EMBEDDING_MODEL` | Model selection (OpenRouter). The API key is in the n8n credential, not here. |
| `ALERT_EMAIL_TO` | Recipient of hot-lead alerts, review requests, errors and the daily report |
| `HOT_LEAD_THRESHOLD` | AI score from which a lead is "hot" (default 70) |
| `DOC_CONFIDENCE_THRESHOLD` | Minimum extraction confidence for automatic booking (default 0.85) |
| `TWENTY_ENCRYPTION_KEY` | Encrypts secrets stored by Twenty (API keys). Keep a backup. |

After changing `.env`: `docker compose up -d` (recreates the affected containers).

## 7. Security notes

- `.env` is git-ignored; `.env.example` contains only placeholders.
- **Env access in workflows:** workflows read non-secret settings and the HMAC
  secret through `$env` (n8n's default `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`). That means
  anyone who can *edit* workflows could read every n8n container variable. On
  this single-owner demo instance, that is the same trust level as the owner
  account. For a multi-user production setup, set it to `true` and move settings
  into n8n Variables or a config table.
- Code node JavaScript runs in the separate `n8n-runners` container, which has
  no access to n8n's environment or database.
- Both inbound webhooks are HMAC-signed and time-limited (5 min). Unsigned calls are dropped and logged.
  The upload webhook needs `X-Upload-Token`.
- **What goes to the LLM:** lead form data (WF-02), PDFs matching `INVOICE_MAIL_QUERY` or
  uploaded with the token (WF-04), and chat messages plus the order data returned by a successful
  lookup (WF-05). Text from leads and documents is passed as data, and the model
  is told not to follow instructions in it.
- Twenty blocks outgoing webhooks to private IPs; only `n8n-main` is allowlisted
  (`OUTBOUND_HTTP_ALLOWED_INTERNAL_HOSTS`).
- The Twenty and Odoo credentials are restricted to their Docker hostnames
  (*Allowed domains*), so n8n refuses to send those keys anywhere else.
- The chat is public (no login, as on a website). Order data is only returned for a matching
  order number **and** customer email; failed lookups are logged (`chat.order_lookup_failed`).
- Postgres is exposed only on `127.0.0.1`. Redis, the n8n worker and the Twenty worker have no host ports.
- `N8N_SECURE_COOKIE=false` is only for plain-http localhost. Behind HTTPS, set it to `true`.

## 8. Reset everything

```bash
docker compose down -v     # deletes ALL data: n8n, project DB, Odoo
```
