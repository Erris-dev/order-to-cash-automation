# Runbook

How to tell what's wrong and fix it. Commands run from the project folder.

## 0. First look

```bash
docker compose ps                                                     # all Up / healthy? (odoo-init: Exited (0) is normal)
curl -s localhost:5678/healthz/readiness                              # n8n main
docker compose exec -T n8n-worker wget -qO- localhost:5678/healthz/readiness
docker compose logs --since 10m n8n-main n8n-worker | grep -iE "error|warn" | tail -30
```

Most recent errors and events:

```bash
docker compose exec -T postgres psql -U postgres -d automation -c \
  "select occurred_at, workflow_name, node_name, left(error_message,100), execution_url from workflow_errors order by id desc limit 10;"
docker compose exec -T postgres psql -U postgres -d automation -c \
  "select occurred_at, event_type, left(message,100) from event_log order by id desc limit 20;"
```

Each error row has an `execution_url`. Open it to see the failing node's input and output.
After fixing the cause you can **retry** the execution in n8n (*Executions → … → Retry*).

## 1. Symptoms → causes

### Error alert email: "WF-01 Lead Intake – Find Company / Upsert Person …"
Twenty unreachable or the API key is invalid.
- `curl -s localhost:3000/healthz`. If it's down: `docker compose up -d twenty-server twenty-worker`.
- 401 in the execution → API key revoked; create a new one in Twenty and update `Twenty – Muster`.
- The lead itself is safe: it's in `leads` with `status = 'received'`. WF-06 reports it at night.
  To re-sync, resend the original payload (same email → same lead, `duplicate: true`).

### Website gets 401 from `/webhook/lead-intake`
`event_log` → `lead.rejected` with the reason:
- `signature_mismatch`: the site uses a different `LEAD_WEBHOOK_HMAC_SECRET`, or signs a re-serialised
  body instead of the exact bytes it sends.
- `timestamp_outside_window`: the site's clock is off by more than 5 minutes, or the request was replayed.
- `missing_signature_headers`: headers `X-Muster-Timestamp` / `X-Muster-Signature: sha256=…` are missing.

### A deal was moved to *Customer* but no Odoo order appears
1. `event_log` has `webhook.rejected`? → secret mismatch. Re-run **WF-00** (it re-registers the webhook with
   the current `TWENTY_WEBHOOK_SECRET`).
2. No WF-03 execution at all? → the webhook isn't registered or is blocked:
   - run WF-00 again;
   - Twenty must allow the target: `OUTBOUND_HTTP_ALLOWED_INTERNAL_HOSTS: n8n-main` (compose);
   - `docker compose logs twenty-worker | grep -i webhook`.
3. WF-03 ran but stopped at *Is New Win?* → the update didn't change `stage` (expected), or the stage isn't `CUSTOMER`.
4. Nothing else helps: WF-06 replays missed wins every night, or run WF-06 now (*Execute workflow*).

### "Odoo product CRM-DEAL not found" / tax "19% I" not found
Odoo master data missing (e.g. a fresh Odoo database): `docker compose up -d odoo-init` re-applies
`db/odoo-setup.py` (idempotent).

### Invoices are not picked up from Gmail
- The mail must match `INVOICE_MAIL_QUERY` (e.g. sent to `you+invoices@gmail.com`, PDF attached).
- Gmail credential expired → n8n shows the credential as invalid. If the Google app is in *Testing* mode,
  tokens expire after 7 days: publish the app, then reconnect the credential.
- Uploading the identical file again is ignored on purpose (`document.duplicate_file` in `event_log`).

### Many invoices end up in review
Look at `documents.validation_errors`:
- `confidence … below 0.85`: scans (legibility fair/poor) never auto-post by design.
- Arithmetic errors on clean PDFs: the model misread. Try `LLM_VISION_MODEL` with a stronger model.
- `possible duplicate`: correct behaviour; reject it via the email link.

### LLM errors (`lead.scored_fallback`, "LLM request failed")
- OpenRouter credits used up or key revoked → check at openrouter.ai, update `OpenRouter – Muster`.
- Model renamed or retired → set `LLM_MODEL` / `LLM_VISION_MODEL` / `LLM_EMBEDDING_MODEL` in `.env`,
  then `docker compose up -d`. If you change the **embedding** model, re-run **WF-05a** (vectors must match).
- Leads still get a fallback score (≤ 69, flagged), so nothing gets stuck.

### Chatbot answers "no information" for everything
`select count(*) from kb_chunks;` is 0 → run **WF-05a**. After editing `knowledge-base/*.md`, run it again.

### Code node error "Task request timed out … not matched to a runner"
The runner sidecar is down: `docker compose up -d n8n-runners n8n-runners-main`. Its version must match n8n's.

### No emails at all (alerts, reports, reviews)
WF-10 executions show the Gmail error. Fix the `Gmail – Muster` credential. Nothing else depends on mail:
errors are still logged and review items still created.

### Review link says "Link not valid"
Links are single-use and expire when the item is decided. A newer reconciliation report refreshes the
link for still-open mismatches. Decide old items directly in the database if needed:
`update review_queue set status='approved', decided_by='db', decided_at=now() where id=…;`

## 2. Reading the reconciliation report (WF-06)

| Kind | Meaning | What to do |
|---|---|---|
| `amount_mismatch` | Twenty amount ≠ Odoo order net | Decide which is right; fix the other side; mark resolved |
| `order_cancelled` | Won in CRM, order cancelled in Odoo | Move the opportunity back or re-create the order |
| `order_missing_in_odoo` | Order deleted in Odoo | Re-create it, or remove the row from `sync_map` so WF-06 replays the win |
| `opportunity_not_won` | Order exists, opportunity no longer at Customer | Usually a deal reopened: cancel the order or move the deal back |
| `name_mismatch` | Customer renamed on one side | Align the names |
| `company_missing_in_crm` / `customer_missing_in_odoo` | Record deleted on one side | Restore it or clean up `sync_map` |
| `lead_not_synced` | Lead never reached Twenty | Check WF-01 errors; resend the lead |

## 3. Maintenance

**Backup**

```bash
docker compose exec -T postgres pg_dumpall -U postgres | gzip > backup-$(date +%F).sql.gz
docker run --rm -v o2c_odoo_data:/d -v "$PWD":/b alpine tar czf /b/odoo-filestore-$(date +%F).tgz -C /d .
docker run --rm -v o2c_twenty_data:/d -v "$PWD":/b alpine tar czf /b/twenty-storage-$(date +%F).tgz -C /d .
```

Keep `.env` safe as well. Without `N8N_ENCRYPTION_KEY`, every n8n credential has to be re-entered.

**Restore:** `docker compose down -v`, `docker compose up -d postgres`, wait, then
`gunzip -c backup.sql.gz | docker compose exec -T postgres psql -U postgres`, then restore the volumes and
`docker compose up -d`.

**Change a database password:** `.env` only applies on first start. Run
`ALTER ROLE automation PASSWORD '…';` in Postgres, update `.env` and the n8n credential, then `docker compose up -d`.

**Update versions:** change the image tags in `docker-compose.yml` (`n8nio/n8n` and `n8nio/runners`
**together**), `docker compose pull && docker compose up -d`, then `./scripts/import-workflows.sh` and run the tests in SETUP §5a.

**After editing workflows in the UI:** `./scripts/export-workflows.sh`, review `workflows/_export/`,
copy changes into `workflows/`, commit.

**Reset all demo data** (deletes everything, including credentials):

```bash
docker compose down -v && docker compose up -d
```

Then follow SETUP from section 3.

## 4. Useful queries

```sql
-- leads that never reached the CRM
select id, email, created_at from leads where status = 'received' and created_at < now() - interval '30 minutes';
-- open review items
select id, item_type, item_id, left(reason, 80), created_at from review_queue where status = 'pending' order by id;
-- invoice outcomes
select status, count(*) from documents group by status;
-- what happened to one lead
select occurred_at, event_type, message from event_log where entity_type = 'lead' and entity_id = '1' order by id;
```
