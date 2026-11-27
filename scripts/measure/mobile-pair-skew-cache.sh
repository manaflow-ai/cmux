#!/usr/bin/env bash
# Leo: "sounds like you could just simulate that".
# Linux headless cross-source connectivity: binary cache miss then hit, same preexisting Cargo cache.
# cmux-ci test --setup rust --timeout 3600 -- \
#   bash scripts/measure/mobile-pair-skew-cache.sh OLD_CHECKOUT HEAD_CHECKOUT
# CARGO_TARGET_DIR must already contain release outputs; no dependency-cold claim is made.
# Import: scripts/bench/cmux-bench mobile-pair-cache --build local --host anywhere --import LOG
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo "This headless harness requires Linux and GNU time" >&2; exit 2; }
old=$(cd "${1:?usage: mobile-pair-skew-cache.sh OLD_CHECKOUT HEAD_CHECKOUT}" && pwd)
head=$(cd "${2:?usage: mobile-pair-skew-cache.sh OLD_CHECKOUT HEAD_CHECKOUT}" && pwd)
[[ -d "${CARGO_TARGET_DIR:?set CARGO_TARGET_DIR to the existing Cargo cache}/release" ]] ||
  { echo "The Cargo release cache must already exist" >&2; exit 2; }
export CARGO_TARGET_DIR
CARGO_TARGET_DIR=$(cd "$CARGO_TARGET_DIR" && pwd)
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'python3 -I -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$work"' EXIT
export SKEW_BINARY_CACHE_DIR="$work/binaries"
host_sha=$(git -C "$old" rev-parse HEAD)
dial_sha=$(git -C "$head" rev-parse HEAD)
for arm in binary-miss binary-hit; do
  status=0
  /usr/bin/time -f '%e %U %S' -o "$work/$arm.time" \
    bash "$root/scripts/ci/mobile-pair-skew.sh" "$old" "$head" > "$work/$arm.log" 2>&1 || status=$?
  cat "$work/$arm.log"
  python3 -I - "$work/$arm.time" "$work/$arm.log" "$arm" "$status" "$host_sha" "$dial_sha" <<'PY'
import json, math, pathlib, sys
timing, log, arm, status, host_sha, dial_sha = sys.argv[1:]
wall, user, system = map(float, pathlib.Path(timing).read_text().splitlines()[-1].split())
lines = pathlib.Path(log).read_text().splitlines()
hits = sum(line.startswith("binary cache hit:") for line in lines)
misses = sum(line.startswith("binary cache miss:") for line in lines)
valid = int(status) == 0 and all(math.isfinite(x) and x >= 0 for x in (wall, user, system))
valid = valid and (hits, misses) == ((0, 2) if arm == "binary-miss" else (2, 0))
row = dict(schema="mobile-pair-cache/v1", arm=arm, host_sha=host_sha, dial_sha=dial_sha,
           cargo_cache="preexisting", wall_s=wall, user_s=user, system_s=system,
           hits=hits, misses=misses, exit_code=int(status), valid=valid)
print("MOBILE-PAIR-CACHE " + json.dumps(row, sort_keys=True), flush=True)
if not valid:
    raise SystemExit("pair run failed or did not exercise the expected cache state")
PY
done
