#!/bin/bash
# Complexity compares trees and baseline files, not ancestry. Fetch the exact
# comparison commit without downloading the repository's entire history.
set -euo pipefail

revision="${1:-}"
if [ -z "$revision" ] || [ "$revision" = "0000000000000000000000000000000000000000" ]; then
  exit 0
fi
if [[ ! "$revision" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "Expected a full comparison commit SHA" >&2
  exit 2
fi
if ! git cat-file -e "${revision}^{commit}" 2>/dev/null; then
  # Depth 1 only in a shallow checkout (CI's): in a full clone --depth writes
  # .git/shallow and truncates history for every worktree sharing it.
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  git -c protocol.version=2 fetch --no-tags ${depth[@]+"${depth[@]}"} origin "$revision"
fi
git cat-file -e "${revision}^{commit}"
