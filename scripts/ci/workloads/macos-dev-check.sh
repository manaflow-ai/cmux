#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
state="${CMUX_WORKLOAD_STATE_ROOT:?CMUX_WORKLOAD_STATE_ROOT is required}"
derived="$state/derived-data"

stage() {
  python3 "$root/scripts/ci/cmux_workload_profile.py" stage "$1" "$2"
}

cd "$root"
mkdir -p "$state"

stage start setup
export CMUX_DEV_BACKEND_MODE=local
export CMUX_RELOAD_NO_GLOBAL_CLI_LINKS=1
stage end setup

stage start compile
./scripts/reload.sh   --tag cmux-workload-dev-check   --derived-data "$derived"   --no-global-cli-links
stage end compile

stage start validation
app="$derived/Build/Products/Debug/cmux DEV cmux-workload-dev-check.app"
if [[ ! -d "$app" ]]; then
  app="$derived/Build/Products/Debug/cmux DEV.app"
fi
test -x "$app/Contents/MacOS/cmux DEV"
stage end validation
