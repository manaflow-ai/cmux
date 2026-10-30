#!/usr/bin/env bash
# Claim a cmux-tui tree key at the cmux-ci controller's tree-claim authority.
#
# Usage: cmux-tui-tree-claim.sh KEY
#
# cmux-tui-artifacts.yml elects one run per tree key to build it. Reading the
# Actions run list and taking the oldest active run was a check-then-act
# election on an eventually consistent API: on 2026-10-11 three runs of tree
# bfbd3600debc each found no older owner while run 38126044406 built it
# (cx-73f2). The controller decides instead, atomically: the first claimant of
# a key owns it, every later one is told that owner, and the claim passes on
# only after the owner run completed. The claimant is identified by this
# job's GitHub Actions OIDC token (the job needs `id-token: write`).
#
# Prints `owner=<run id> granted=true|false` and exits 0, or exits 3 when the
# authority cannot be asked (no OIDC token, network, a 5xx): the caller then
# falls back to its own election. Env: CMUX_TUI_TREE_CLAIM_URL (default
# https://gh-events.cmux.com/github/tree-claim).
set -euo pipefail
key="${1:?usage: cmux-tui-tree-claim.sh KEY}"
[[ "$key" =~ ^[0-9a-f]{40}$ ]] || { echo "error: KEY must be a 40-hex tree key" >&2; exit 2; }
url="${CMUX_TUI_TREE_CLAIM_URL:-https://gh-events.cmux.com/github/tree-claim}"
if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
  echo "tree claim: no OIDC token in this job (needs permissions id-token: write)" >&2
  exit 3
fi
token="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 20 \
  -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=cmux-ci-tree-claim" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])' 2>/dev/null)" || token=""
[[ -n "$token" ]] || { echo "tree claim: could not get an OIDC token" >&2; exit 3; }
body="$(mktemp)"; trap 'rm -f "$body"' EXIT
code="$(curl --silent --show-error --connect-timeout 5 --max-time 30 -o "$body" -w '%{http_code}' \
  -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  --data "{\"key\":\"$key\"}" "$url" 2>/dev/null)" || code=000
if [[ "$code" != 200 ]]; then
  echo "tree claim: the authority answered HTTP $code: $(head -c 300 "$body")" >&2
  exit 3
fi
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
owner, granted = int(d["owner_run_id"]), bool(d["granted"])
if owner <= 0:
    raise SystemExit(3)
print(f"owner={owner} granted={str(granted).lower()}")
' "$body" || exit 3
