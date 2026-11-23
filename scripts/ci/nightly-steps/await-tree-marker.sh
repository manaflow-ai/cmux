#!/usr/bin/env bash
# nightly.yml await-nightly-tree-marker: "Wait for the build commit's tree-commit marker".
# NIGHTLY_NEXT_TREE_AT_INSTALL: main's promote guard skipped its tree-commit
# marker check (G5) for a build that started before its tree was published, so
# it runs here before publish-nightly: the build commit's marker must exist,
# name the build's tree key, and name the commit whose client build-nightly-app
# installed as the tree's publisher. Then the published app carries exactly the
# tree's client. Read-only: files.cmux.com only.
# A build that bundled the newest published tree because its own was not published
# yet (app-bundle-cmux-tui-client.sh, INSTALLED_KEY differs from KEY) cannot wait for
# its commit's marker: that names a tree it did not install. It passes once tree
# INSTALLED_KEY is published and verified (tree-commit-marker.sh tree-ready) with
# INSTALLED as its publisher, so the app still carries exactly a published tree's
# client (RFD 0021 row 2).
# Env: BUILD_SHA, KEY, INSTALLED, INSTALLED_KEY (optional; the tree the build
# installed); CMUX_TREE_MARKER_WAIT_SECONDS (default 3000),
# CMUX_TREE_MARKER_POLL_SECONDS (default 20), CMUX_TUI_PIN_BASE.
set -euo pipefail
[[ "$BUILD_SHA" =~ ^[0-9a-f]{40}$ && "$KEY" =~ ^[0-9a-f]{40}$ && "$INSTALLED" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "error: the build commit, tree key or installed client commit is missing" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"
marker="$base/tree-commits/$BUILD_SHA.json"
deadline=$(( $(date +%s) + ${CMUX_TREE_MARKER_WAIT_SECONDS:-3000} ))
installed_key="${INSTALLED_KEY:-}"
if [[ -n "$installed_key" && "$installed_key" != "$KEY" ]]; then
  [[ "$installed_key" =~ ^[0-9a-f]{40}$ ]] || { echo "error: INSTALLED_KEY '$installed_key' is not a 40-hex tree key" >&2; exit 1; }
  # One read, no wait: a tree the bundle step installed is already published. tree-ready
  # verifies its sha256 against its publisher's manifest; any read failure refuses.
  rc=0
  out="$(bash "$here/scripts/cmux-next/tree-commit-marker.sh" tree-ready "$installed_key" 2>/dev/null)" || rc=$?
  if (( rc != 0 )); then
    echo "::error title=tree marker::fallback tree $installed_key is not published or could not be verified (tree-ready exit $rc); nothing is published"
    exit 1
  fi
  published_by="$(sed -n 's/^publishedBy=//p' <<<"$out" | head -1)"
  if [[ "$published_by" != "$INSTALLED" ]]; then
    echo "::error title=tree marker::fallback tree $installed_key was published by ${published_by:-nobody}, but this build installed the client of $INSTALLED; nothing is published"
    exit 1
  fi
  echo "::warning title=cmux-tui fallback tree::this build ships the client of published tree $installed_key (by $INSTALLED), not its own tree $KEY, which was not published when it bundled"
  exit 0
fi
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
