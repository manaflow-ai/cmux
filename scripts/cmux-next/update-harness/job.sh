#!/usr/bin/env bash
# Builds a tagged DEV app and runs the update harness (run.py) on it.
# GUI host only: nx-remote --needs gui --needs xcode27 -- scripts/cmux-next/update-harness/job.sh <tag> [out] [run.py flags...]
# (for example --handoff --sessions). The tagged build has no Cloud backend (CMUX_DEV_BACKEND_MODE=local).
# With a fleet-built app (nx-remote sets NX_APP and NX_APP_TAG) it builds nothing and runs on that app:
#   nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- scripts/cmux-next/update-harness/job.sh <tag> ...
set -euo pipefail
tag="${1:?usage: job.sh <tag> [out] [run.py flags...]}"
out="${2:-${NX_ARTIFACTS:-${TMPDIR:-/tmp}}/update-harness}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo"
export CMUX_DEV_BACKEND_MODE=local
if [[ -n "${NX_APP:-}" ]]; then
  # nx-remote --app-from-fleet: the fleet built this exact commit's app (acpmux inside).
  [[ "${NX_APP_TAG:-}" == "$tag" ]] || {
    echo "job.sh: tag $tag is not the fleet app's tag ${NX_APP_TAG:-<unset>}; pass the --tag given to nx-remote" >&2
    exit 2
  }
  [[ -d "$NX_APP" ]] || { echo "job.sh: NX_APP $NX_APP is not an app" >&2; exit 1; }
  [[ "${NX_APP_SOCKET:-}" == "/tmp/cmux-debug-$tag.sock" ]] || {
    echo "job.sh: NX_APP_SOCKET ${NX_APP_SOCKET:-<unset>} is not /tmp/cmux-debug-$tag.sock, the socket run.py uses" >&2
    exit 2
  }
  app="$NX_APP"
  echo "job.sh: using the fleet-built app $app (no host build)"
else
  CMUX_FLEET_BUILD_TAG="$tag" ./scripts/cmux-next/build-acpmux.sh
  ./scripts/reload.sh --tag "$tag"
  app=""
  for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/"cmux DEV $tag.app"; do
    [[ -d "$candidate" && ( -z "$app" || "$candidate" -nt "$app" ) ]] && app="$candidate"
  done
  [[ -n "$app" ]] || { echo "job.sh: no built cmux DEV $tag.app" >&2; exit 1; }
fi
python3 -I scripts/cmux-next/update-harness/run.py --app "$app" --tag "$tag" --out "$out" "${@:3}"
