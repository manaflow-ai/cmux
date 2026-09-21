#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
state_root="${1:?semantic state root is required}"
result_path="${2:?semantic result path is required}"
runner="$root/scripts/ci/cmux_workload_profile.py"
registry="$root/scripts/ci/cmux-workload-profiles.json"

if [ ! -f "$runner" ] || [ ! -f "$registry" ]; then
  echo "canonical cmux.macos.compile-admission@1 is unavailable; keep persistent routing disabled until #13411 is on the exact source" >&2
  exit 78
fi

python3 "$runner" describe cmux.macos.compile-admission |
  python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["id"] == "cmux.macos.compile-admission" and value["generation"] == 1'

state_class=cold
if [ -d "$state_root" ] && [ -n "$(find "$state_root" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  state_class=compiler-warm
fi

exec python3 "$runner" run cmux.macos.compile-admission \
  --generation 1 \
  --state-class "$state_class" \
  --state-root "$state_root" \
  --result "$result_path"
