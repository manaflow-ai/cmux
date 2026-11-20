#!/usr/bin/env bash
# nightly.yml await-nightly-tree-marker: "Wait for the build commit's tree-commit marker".
# NIGHTLY_NEXT_TREE_AT_INSTALL: main's promote guard skipped its tree-commit
# marker check (G5) for a build that started before its tree was published, so
# it runs here before publish-nightly: the build commit's marker must exist,
# name the build's tree key, and name the commit whose client build-nightly-app
# installed as the tree's publisher. Then the published app carries exactly the
# tree's client. Read-only: files.cmux.com only.
# Env: BUILD_SHA, KEY, INSTALLED; CMUX_TREE_MARKER_WAIT_SECONDS (default 3000),
# CMUX_TREE_MARKER_POLL_SECONDS (default 20), CMUX_TUI_PIN_BASE.
set -euo pipefail
[[ "$BUILD_SHA" =~ ^[0-9a-f]{40}$ && "$KEY" =~ ^[0-9a-f]{40}$ && "$INSTALLED" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "error: the build commit, tree key or installed client commit is missing" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"
marker="$base/tree-commits/$BUILD_SHA.json"
deadline=$(( $(date +%s) + ${CMUX_TREE_MARKER_WAIT_SECONDS:-3000} ))
while :; do
  rc=0
  bash "$here/scripts/cmux-next/tree-commit-marker.sh" check "$BUILD_SHA" >/dev/null || rc=$?
  if (( rc == 0 )); then
    body="$(curl -fsS --proto '=https' --connect-timeout 20 --max-time 60 --retry 3 "$marker?t=$(date +%s)")"
    read -r key published_by < <(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["key"], d["publishedBy"])' "$body")
    [[ "$key" == "$KEY" ]] || { echo "::error title=tree marker::$marker names tree $key, not the build's $KEY; nothing is published"; exit 1; }
    if [[ "$published_by" != "$INSTALLED" ]]; then
      echo "::error title=tree marker::tree $KEY was published by $published_by, but this build installed the client of $INSTALLED; nothing is published (the next build takes the published tree)"
      exit 1
    fi
    echo "tree $KEY is published by $INSTALLED, the client this build installed; $marker is written"
    exit 0
  fi
  (( rc == 1 || rc == 3 )) || { echo "error: tree-commit-marker.sh check exited $rc" >&2; exit 1; }
  (( $(date +%s) < deadline )) || { echo "::error title=tree marker::$marker is not written in time; nothing is published"; exit 1; }
  sleep "${CMUX_TREE_MARKER_POLL_SECONDS:-20}"
done
