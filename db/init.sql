-- =============================================================================
-- Order-to-Cash Automation – Postgres bootstrap
--
-- Runs ONCE, on the first start of an empty postgres volume
-- (/docker-entrypoint-initdb.d). Passwords are read from the container's
-- environment with psql's \getenv, so no secret is stored in this file.
--
-- Creates:
--   role n8n        + database n8n         (n8n internal tables, managed by n8n)
--   role automation + database automation  (project tables, below)
--   role odoo       + database odoo        (initialised by the odoo-init service)
--   role twenty     + database twenty      (Twenty CRM runs its own migrations)
-- =============================================================================

\set ON_ERROR_STOP on

\getenv n8n_pw        N8N_DB_PASSWORD
\getenv automation_pw AUTOMATION_DB_PASSWORD
\getenv odoo_pw       ODOO_DB_PASSWORD
\getenv twenty_pw     TWENTY_DB_PASSWORD

CREATE ROLE n8n        LOGIN PASSWORD :'n8n_pw';
CREATE ROLE automation LOGIN PASSWORD :'automation_pw';
CREATE ROLE odoo       LOGIN PASSWORD :'odoo_pw' CREATEDB;  -- Odoo refuses to run as superuser
CREATE ROLE twenty     LOGIN PASSWORD :'twenty_pw';

CREATE DATABASE n8n        OWNER n8n        ENCODING 'UTF8';
CREATE DATABASE automation OWNER automation ENCODING 'UTF8';
CREATE DATABASE odoo       OWNER odoo       ENCODING 'UTF8' TEMPLATE template0;
CREATE DATABASE twenty     OWNER twenty     ENCODING 'UTF8';

-- -----------------------------------------------------------------------------
-- Project database
-- -----------------------------------------------------------------------------
\connect automation

-- Extensions need superuser, so create them before switching role.
CREATE EXTENSION IF NOT EXISTS vector;    -- pgvector: chatbot knowledge base
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid(), digest()

SET ROLE automation;
SET TIME ZONE 'Europe/Berlin';

-- Keeps updated_at current on every UPDATE.
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- -----------------------------------------------------------------------------
-- leads – every web form submission (WF-01) and its AI qualification (WF-02)
-- -----------------------------------------------------------------------------
CREATE TABLE leads (
  id                  bigserial   PRIMARY KEY,
  dedupe_key          text        NOT NULL UNIQUE,     -- sha256(lower(trim(email)))
  email               text        NOT NULL,
  first_name          text,
  last_name           text,
  company             text,
  phone               text,
  country             char(2),                         -- ISO 3166-1 alpha-2
  language            char(2)     NOT NULL DEFAULT 'de' CHECK (language IN ('de', 'en')),
  message             text,
  source              text        NOT NULL DEFAULT 'website',
  raw_payload         jsonb       NOT NULL,            -- last payload as received
  submission_count    integer     NOT NULL DEFAULT 1,  -- incremented on duplicates
  crm_person_id       text,                          -- Twenty person id (uuid)
  crm_company_id      text,
  crm_opportunity_id  text,
  ai_score            smallint    CHECK (ai_score BETWEEN 0 AND 100),
  ai_industry         text,
  ai_company_size     text,
  ai_intent           text,
  ai_reason           text,
  ai_model            text,
  ai_fallback         boolean     NOT NULL DEFAULT false,  -- true if LLM output was invalid
  scored_at           timestamptz,
  status              text        NOT NULL DEFAULT 'received'
                                  CHECK (status IN ('received', 'synced', 'scored', 'error')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX leads_created_at_idx ON leads (created_at);
CREATE INDEX leads_crm_opportunity_idx ON leads (crm_opportunity_id);
CREATE TRIGGER leads_updated_at BEFORE UPDATE ON leads
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- sync_map – CRM (Twenty) ID <-> Odoo ID (WF-03 writes, WF-06 reconciles)
-- -----------------------------------------------------------------------------
CREATE TABLE sync_map (
  id              bigserial   PRIMARY KEY,
  entity_type     text        NOT NULL CHECK (entity_type IN ('customer', 'order')),
  crm_object      text        NOT NULL,                -- 'companies' | 'people' | 'opportunities'
  crm_id          text        NOT NULL,                -- Twenty record id (uuid)
  odoo_model      text        NOT NULL,                -- 'res.partner' | 'sale.order'
  odoo_id         integer     NOT NULL,
  odoo_name       text,                                -- e.g. sales order reference S00012
  last_synced_at  timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_type, crm_id),
  UNIQUE (entity_type, odoo_id)
);

-- -----------------------------------------------------------------------------
-- documents – supplier invoices processed by WF-04
-- -----------------------------------------------------------------------------
CREATE TABLE documents (
  id                 bigserial     PRIMARY KEY,
  source             text          NOT NULL DEFAULT 'email',
  email_message_id   text,
  email_from         text,
  file_name          text          NOT NULL,
  file_sha256        text          NOT NULL UNIQUE,    -- same file is never processed twice
  mime_type          text,
  file_base64        text,                             -- original PDF, attached to the Odoo bill (WF-04b)
  supplier_name      text,
  supplier_vat_id    text,
  invoice_number     text,
  invoice_date       date,
  due_date           date,
  currency           char(3),
  net_amount         numeric(12,2),
  vat_amount         numeric(12,2),
  total_amount       numeric(12,2),
  line_items         jsonb,
  extraction_raw     jsonb,                            -- untouched LLM output
  confidence         numeric(4,3)  CHECK (confidence BETWEEN 0 AND 1),
  validation_errors  jsonb         NOT NULL DEFAULT '[]'::jsonb,
  status             text          NOT NULL DEFAULT 'received'
                                   CHECK (status IN ('received', 'booked', 'needs_review', 'approved', 'rejected')),
                                   -- approved = a human approved it via WF-09; draft bill waits in Odoo
  odoo_bill_id       integer,
  created_at         timestamptz   NOT NULL DEFAULT now(),
  updated_at         timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX documents_status_idx ON documents (status);
CREATE INDEX documents_supplier_invoice_idx ON documents (supplier_name, invoice_number);
CREATE TRIGGER documents_updated_at BEFORE UPDATE ON documents
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- review_queue – anything a human must handle (WF-04 invoices, WF-05 chatbot
-- escalations, WF-06 sync mismatches; approved/rejected via WF-09)
-- -----------------------------------------------------------------------------
CREATE TABLE review_queue (
  id                   bigserial   PRIMARY KEY,
  item_type            text        NOT NULL CHECK (item_type IN ('document', 'lead', 'sync_mismatch', 'support_request')),
  item_id              bigint,                         -- id in the table named by item_type
  reason               text        NOT NULL,
  payload              jsonb       NOT NULL DEFAULT '{}'::jsonb,
  status               text        NOT NULL DEFAULT 'pending'
                                   CHECK (status IN ('pending', 'approved', 'rejected')),
  approval_token_hash  text        UNIQUE,             -- sha256 of the token in the email link
  decided_by           text,
  decided_at           timestamptz,
  decision_note        text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX review_queue_pending_idx ON review_queue (created_at) WHERE status = 'pending';
CREATE TRIGGER review_queue_updated_at BEFORE UPDATE ON review_queue
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- kb_chunks – chatbot knowledge base (WF-05)
-- Column names match n8n's "Postgres PGVector Store" node defaults
-- (id / text / metadata / embedding), so the node can use this table directly
-- with table name = kb_chunks. `embedding` has no fixed dimension, so the
-- embedding model can be swapped; re-ingest the KB after changing it.
-- A small KB (< 10k chunks) needs no ANN index – exact search is fast enough.
-- -----------------------------------------------------------------------------
CREATE TABLE kb_chunks (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  text        text        NOT NULL,
  metadata    jsonb       NOT NULL DEFAULT '{}'::jsonb,  -- {source, language, title, chunk}
  embedding   vector,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX kb_chunks_language_idx ON kb_chunks ((metadata->>'language'));

-- -----------------------------------------------------------------------------
-- workflow_errors – written by the central error workflow (WF-07)
-- -----------------------------------------------------------------------------
CREATE TABLE workflow_errors (
  id              bigserial   PRIMARY KEY,
  workflow_id     text,
  workflow_name   text        NOT NULL,
  node_name       text,
  error_message   text        NOT NULL,
  error_details   jsonb,                               -- description, stack, http code …
  execution_id    text,
  execution_url   text,
  execution_mode  text,                                -- trigger | webhook | manual …
  retry_of        text,
  occurred_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX workflow_errors_occurred_at_idx ON workflow_errors (occurred_at);

-- -----------------------------------------------------------------------------
-- event_log – audit trail of business events from every workflow
-- -----------------------------------------------------------------------------
CREATE TABLE event_log (
  id             bigserial   PRIMARY KEY,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  workflow_name  text        NOT NULL,
  event_type     text        NOT NULL,                 -- e.g. lead.received, order.created
  entity_type    text,                                 -- lead | document | order | …
  entity_id      text,
  message        text,
  data           jsonb       NOT NULL DEFAULT '{}'::jsonb,
  execution_id   text
);
CREATE INDEX event_log_occurred_at_idx ON event_log (occurred_at);
CREATE INDEX event_log_event_type_idx ON event_log (event_type, occurred_at);

RESET ROLE;
