#!/usr/bin/env bash
# Uploads one or more PDFs to WF-04 (document processing) without email.
#
# Usage:
#   ./scripts/upload-document.sh sample-documents/01-invoice-ok-paper-19pct.pdf
#   ./scripts/upload-document.sh sample-documents/*.pdf
#
# Env overrides: UPLOAD_URL (default http://localhost:5678/webhook/invoice-upload),
#                DOC_UPLOAD_TOKEN (default: read from .env)
set -euo pipefail

cd "$(dirname "$0")/.."
(( $# > 0 )) || { echo "usage: $0 <file.pdf> [more.pdf ...]" >&2; exit 1; }

url="${UPLOAD_URL:-http://localhost:5678/webhook/invoice-upload}"
token="${DOC_UPLOAD_TOKEN:-$(grep -E '^DOC_UPLOAD_TOKEN=' .env | cut -d= -f2-)}"
[[ -n "$token" ]] || { echo "DOC_UPLOAD_TOKEN not found in .env" >&2; exit 1; }

for f in "$@"; do
  echo "POST $url  ($f)"
  curl -sS -X POST "$url" -H "X-Upload-Token: $token" \
    -F "file=@$f;type=application/pdf" -w '\nHTTP %{http_code}\n'
done
