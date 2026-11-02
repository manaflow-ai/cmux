#!/usr/bin/env bash
# Usage: scripts/ci/ios-sim-fetch-commit.sh SHA
#
# Makes commit SHA readable in the current checkout, for cmux-next-ios-sim.sh
# listperf's base= (2026-11-01, cmux#31442). A fleet step's checkout has no
# `origin` remote: the worker checks it out from glaeda's git mirror (borrowed
# through objects/info/alternates) or the host reference, and fetches a commit
# neither holds from GitHub by URL. This takes a commit the same way, in order:
#   1. already readable here (the mirror's objects are borrowed);
#   2. `origin`, when the checkout has one (a lane's own clone);
#   3. glaeda's mirror ($CMUX_CI_STEP_GLAEDA_MIRROR_DIR, default
#      /Users/Shared/cmux-build-fleet/git, then cmux.git), the step's source;
#   4. the host reference ($CMUX_CI_STEP_REFERENCE), when set;
#   5. GitHub by URL ($CMUX_IOS_SIM_COMMIT_REMOTE, default the public repo).
# A shallow checkout fetches with --depth=1. Exits 1 naming every source tried
# when none has the commit.
set -euo pipefail

sha="${1:-}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "ios-sim-fetch-commit.sh: wants a 40-character commit SHA, got '$sha'" >&2; exit 2; }

have() { git cat-file -e "$sha^{commit}" 2>/dev/null; }
if have; then
  echo "commit $sha: already in the checkout"
  exit 0
fi

depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)

sources=()
git remote get-url origin >/dev/null 2>&1 && sources+=(origin)
mirror="${CMUX_CI_STEP_GLAEDA_MIRROR_DIR:-/Users/Shared/cmux-build-fleet/git}/cmux.git"
[[ -d "$mirror" ]] && sources+=("$mirror")
[[ -n "${CMUX_CI_STEP_REFERENCE:-}" && -d "${CMUX_CI_STEP_REFERENCE}" ]] && sources+=("$CMUX_CI_STEP_REFERENCE")
sources+=("${CMUX_IOS_SIM_COMMIT_REMOTE:-https://github.com/manaflow-ai/cmux.git}")

tried=()
for src in "${sources[@]}"; do
  # Protocol v2 serves any commit the source holds, not only its branch tips.
  if git -c protocol.version=2 fetch -q --no-tags --no-write-fetch-head ${depth[@]+"${depth[@]}"} "$src" "$sha" 2>/dev/null && have; then
    echo "commit $sha: fetched from $src"
    exit 0
  fi
  tried+=("$src")
done
echo "error: commit $sha is in none of: ${tried[*]}" >&2
exit 1
