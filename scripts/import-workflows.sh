#!/usr/bin/env bash
# Imports every workflows/*.json into the running n8n instance.
# Each file carries a fixed workflow id, so re-importing overwrites the existing
# workflow instead of creating a duplicate, and settings.errorWorkflow keeps
# pointing at WF-07.
#
# Usage: ./scripts/import-workflows.sh
set -euo pipefail

cd "$(dirname "$0")/.."

shopt -s nullglob
files=(workflows/*.json)
if (( ${#files[@]} == 0 )); then
  echo "No workflow files in workflows/ – nothing to import."
  exit 0
fi

echo "Importing ${#files[@]} workflow(s)…"
# /workflows is the ./workflows folder mounted read/write into n8n-main.
# MSYS_NO_PATHCONV stops Git Bash on Windows from rewriting /workflows.
MSYS_NO_PATHCONV=1 docker compose exec -T n8n-main \
  n8n import:workflow --separate --input=/workflows --activeState=fromJson

# WF-07 and WF-10 fail import-time activation checks until "Gmail – Muster"
# exists (WF-10 holds the Gmail node, WF-07 calls it).
# Publish them anyway, so failures are still logged to Postgres.
MSYS_NO_PATHCONV=1 docker compose exec -T n8n-main \
  sh -c "n8n publish:workflow --id=o2cWf07ErrorsHdl && n8n publish:workflow --id=o2cWf10SendNotif"

# The running main instance only picks up activations made by the CLI after a
# restart, so restart it to register the webhooks and triggers.
docker compose restart n8n-main

echo "Done. Workflows marked \"active\": true in their JSON are published."
