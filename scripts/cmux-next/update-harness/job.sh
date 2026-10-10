#!/usr/bin/env bash
# Builds a tagged DEV app and runs the update harness (run.py) on it.
# GUI host only: nx-remote --needs gui --needs xcode27 -- scripts/cmux-next/update-harness/job.sh <tag> [out] [run.py flags...]
# (for example --handoff --sessions). The tagged build has no Cloud backend (CMUX_DEV_BACKEND_MODE=local).
set -euo pipefail
tag="${1:?usage: job.sh <tag> [out] [run.py flags...]}"
out="${2:-${NX_ARTIFACTS:-${TMPDIR:-/tmp}}/update-harness}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
export CMUX_DEV_BACKEND_MODE=local
CMUX_FLEET_BUILD_TAG="$tag" ./scripts/cmux-next/build-acpmux.sh
./scripts/reload.sh --tag "$tag"
app=""
for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/"cmux DEV $tag.app"; do
  [[ -d "$candidate" && ( -z "$app" || "$candidate" -nt "$app" ) ]] && app="$candidate"
done
[[ -n "$app" ]] || { echo "job.sh: no built cmux DEV $tag.app" >&2; exit 1; }
python3 -I scripts/cmux-next/update-harness/run.py --app "$app" --tag "$tag" --out "$out" "${@:3}"
