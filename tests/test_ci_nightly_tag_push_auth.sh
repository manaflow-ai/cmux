#!/usr/bin/env bash
# Guards the nightly tag update against regressions to the auth approach.
#
# History:
# - Originally relied on actions/checkout-persisted credentials, which
#   intermittently failed with `fatal: could not read Username for
#   'https://github.com': Device not configured` on the self-hosted runner.
# - Then overlaid a second Authorization header via `-c
#   http.https://github.com/.extraheader=AUTHORIZATION: basic …`, which made
#   GitHub reject the push with `remote: Duplicate header: "Authorization"`
#   because the persisted extraheader was still in effect.
# - Now pushes to an explicit tokenized URL so the push neither depends on
#   persisted creds nor overlays a second Authorization header.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/nightly.yml"

if ! awk '
  /^      - name: Move nightly tag to built commit/ { in_step=1; next }
  in_step && /^      - name:/ { in_step=0 }
  in_step && /GITHUB_TOKEN: \$\{\{ github\.token \}\}/ { saw_token_env=1 }
  in_step && /x-access-token:\$\{GITHUB_TOKEN\}@github\.com\/\$\{GITHUB_REPOSITORY\}\.git/ { saw_token_url=1 }
  in_step && /refs\/tags\/nightly --force/ { saw_push=1 }
  in_step && /\.extraheader=AUTHORIZATION/ { saw_extraheader=1 }
  END {
    if (saw_extraheader) exit 1
    exit !(saw_token_env && saw_token_url && saw_push)
  }
' "$WORKFLOW_FILE"; then
  echo "FAIL: nightly tag push must use a tokenized https URL with github.token (no extraheader overlay)"
  exit 1
fi

echo "PASS: nightly tag push uses tokenized https URL with github.token"
