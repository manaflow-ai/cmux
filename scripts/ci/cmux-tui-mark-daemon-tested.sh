#!/usr/bin/env bash
# Write the write-once marker tree/<key>/daemon-tests.json: the cmux_next_
# daemon tests passed for this cmux-tui tree. request-nightly-next.sh promotes
# a tree whose source.json says daemonTests "separate" only when it exists.
#
# Usage: cmux-tui-mark-daemon-tested.sh <key> [<legacy key>]
# Env: R2_ENDPOINT and the R2 AWS_* credentials; GITHUB_SHA, GITHUB_RUN_ID,
# GITHUB_SERVER_URL and GITHUB_REPOSITORY (the run that tested the tree).
# The marker names no runner OS. Markers written on 2026-10-26 and 27 carry
# an extra "os" field; request-nightly-next.sh and every other reader check
# only that the marker exists, so markers with or without it promote alike.
# Caller: cmux-tui-artifacts.yml publish-tree-tested, after the run's daemon
# tests of this key passed. The publisher (publish-tree)
# publishes without the marker and never write it (cx-y0nf2).
set -euo pipefail

key="${1:-}"
legacy_key="${2:-}"
[[ "$key" =~ ^[0-9a-f]{40}$ ]] || { echo "error: the tree key must be 40 lowercase hex characters" >&2; exit 2; }
[[ -z "$legacy_key" || "$legacy_key" =~ ^[0-9a-f]{40}$ ]] || { echo "error: the legacy key must be 40 lowercase hex characters" >&2; exit 2; }
script_dir="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mark() { # <key>
  local key="$1"
  if curl -fsSL --proto '=https' -o /dev/null "https://files.cmux.com/cmux-tui/tree/$key/daemon-tests.json?verify=$GITHUB_RUN_ID"; then
    echo "tree $key already has a daemon-tests marker"
    return 0
  fi
  python3 - "$key" > "$tmp/daemon-tests.json" <<'PY'
import json, os, sys
print(json.dumps({
    "key": sys.argv[1],
    "commit": os.environ["GITHUB_SHA"],
    "run": os.environ["GITHUB_RUN_ID"],
    "runUrl": f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
    "result": "success",
}, indent=2))
PY
  if ! python3 "$script_dir/upload-r2-object.py" --file "$tmp/daemon-tests.json" --endpoint-url "$R2_ENDPOINT" \
      --bucket cmux-binaries --key "cmux-tui/tree/$key/daemon-tests.json" \
      --cache-control "public, max-age=31536000, immutable" --content-type application/json --write-once; then
    # Another run that tested the same key may have written its own marker
    # between the check and this write-once upload: any marker is valid.
    if curl -fsSL --proto '=https' -o /dev/null "https://files.cmux.com/cmux-tui/tree/$key/daemon-tests.json?verify=$GITHUB_RUN_ID-retry"; then
      echo "tree $key got a daemon-tests marker from another run"
      return 0
    fi
    echo "error: could not write the daemon-tests marker of tree $key" >&2
    return 1
  fi
  echo "marked tree $key as daemon-tested"
}

mark "$key"
if [[ -n "$legacy_key" && "$legacy_key" != "$key" ]]; then
  mark "$legacy_key"
fi
