#!/usr/bin/env bash
# Exports all workflows from the running n8n instance to workflows/_export/
# (one pretty-printed file per workflow, named by workflow id).
# Review the diff, then copy changes into the numbered files in workflows/.
# _export/ is git-ignored because exports can contain pinned test data.
#
# Usage: ./scripts/export-workflows.sh
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p workflows/_export

MSYS_NO_PATHCONV=1 docker compose exec -T n8n-main \
  n8n export:workflow --all --separate --pretty --output=/workflows/_export/

echo "Exported to workflows/_export/:"
ls -1 workflows/_export/
