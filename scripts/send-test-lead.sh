#!/usr/bin/env bash
# Sends a lead payload to WF-01 the way the website would: signed with
# HMAC-SHA256 over "<unix timestamp>.<raw body>".
#
# Usage:
#   ./scripts/send-test-lead.sh test-payloads/lead-de-valid.json
#   ./scripts/send-test-lead.sh test-payloads/lead-de-valid.json --bad-signature   # expect 401
#   ./scripts/send-test-lead.sh test-payloads/lead-de-valid.json --stale           # expect 401 (replay)
#
# Env overrides: WEBHOOK_URL (default http://localhost:5678/webhook/lead-intake),
#                LEAD_WEBHOOK_HMAC_SECRET (default: read from .env)
set -euo pipefail

cd "$(dirname "$0")/.."

payload="${1:?usage: $0 <payload.json> [--bad-signature|--stale]}"
mode="${2:-}"
url="${WEBHOOK_URL:-http://localhost:5678/webhook/lead-intake}"

secret="${LEAD_WEBHOOK_HMAC_SECRET:-$(grep -E '^LEAD_WEBHOOK_HMAC_SECRET=' .env | cut -d= -f2-)}"
[[ -n "$secret" ]] || { echo "LEAD_WEBHOOK_HMAC_SECRET not found in .env" >&2; exit 1; }

timestamp=$(date +%s)
[[ "$mode" == "--stale" ]] && timestamp=$((timestamp - 600))

# Sign the exact bytes that are sent (the file as-is, including any trailing newline).
signature=$({ printf '%s.' "$timestamp"; cat "$payload"; } \
  | openssl dgst -sha256 -hmac "$secret" -hex | sed 's/^.* //')
[[ "$mode" == "--bad-signature" ]] && signature="0000${signature:4}"

echo "POST $url  ($payload${mode:+, $mode})"
curl -sS -X POST "$url" \
  -H 'Content-Type: application/json' \
  -H "X-Muster-Timestamp: $timestamp" \
  -H "X-Muster-Signature: sha256=$signature" \
  --data-binary "@$payload" \
  -w '\nHTTP %{http_code}\n'
