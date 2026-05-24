#!/usr/bin/env bash
# Guards the nightly tag update against checkout credential persistence changes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

if ! awk '
  /^      - name: Move nightly tag to built commit/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_step && /GITHUB_TOKEN: \$\{\{ github\.token \}\}/ { saw_token_env=1 }
  in_step && /http\.https:\/\/github\.com\/\.extraheader=AUTHORIZATION: basic/ { saw_extraheader=1 }
  in_step && /push origin refs\/tags\/nightly --force/ { saw_push=1 }
  END { exit !(saw_token_env && saw_extraheader && saw_push) }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly tag push must use explicit github.token auth"
  exit 1
fi

echo "PASS: nightly tag push uses explicit github.token auth"
