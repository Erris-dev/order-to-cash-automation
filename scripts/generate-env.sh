#!/usr/bin/env bash
# Creates .env from .env.example and replaces every <generate> placeholder
# with a random 32-byte hex secret. Refuses to overwrite an existing .env.
#
# Usage: ./scripts/generate-env.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  echo ".env already exists – not touching it." >&2
  exit 1
fi

rand() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

while IFS= read -r line || [[ -n "$line" ]]; do
  while [[ "$line" == *"<generate>"* ]]; do
    line="${line/<generate>/$(rand)}"
  done
  printf '%s\n' "$line"
done < .env.example > .env

echo "Created .env with fresh random secrets."
echo "Edit ALERT_EMAIL_TO (and N8N_PUBLIC_URL if you use a tunnel) before starting."
