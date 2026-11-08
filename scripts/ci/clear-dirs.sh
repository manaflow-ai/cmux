#!/usr/bin/env bash
# Clear fixed build directories on a persistent runner.
#
# A leftover writer from an earlier job (an indexer under Index.noindex) can
# refill a tree while `rm -rf` walks it, failing with "Directory not empty".
# Renaming is atomic, so each path is gone at once; the renamed copies are
# then deleted best-effort, and later runs sweep what an earlier one left.
set -euo pipefail
for dir in "$@"; do
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    mv -- "$dir" "$dir.stale.${GITHUB_RUN_ID:-local}.$$"
  fi
  rm -rf -- "$dir".stale.* 2>/dev/null || true
done
