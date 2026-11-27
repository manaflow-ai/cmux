#!/usr/bin/env bash
# A fleet job for acpmux_wedge_duress.py: builds a debug acpmux from this tree (the job's own
# upload; a fleet worker has no origin to fetch from) and runs the harness against it.
#   cmux-ci test --route fleet --at SHA --not-tests --artifact DIR -- \
#     bash scripts/cmux-next/acpmux_wedge_duress_job.sh TAG [harness args, e.g. --cpus 4 --cpu-x 12]
# To measure another commit, push a branch of it with the harness commit on top, and run at that.
set -o pipefail
TAG="$1"; shift
cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null; sudo -n true 2>/dev/null && echo sudo-ok
echo "measuring $TAG at $(git rev-parse HEAD 2>/dev/null || echo uploaded-tree)"
T=$(cd cmux-tui && cargo metadata --format-version 1 --no-deps | python3 -c "import json,sys;print(json.load(sys.stdin)['target_directory'])")
(cd cmux-tui && cargo build -p acpmux --bin acpmux 2>&1 | tail -2) || exit 3
ACPMUX_WEDGE_HERE=1 python3 -I scripts/cmux-next/acpmux_wedge_duress.py --acpmux "$T/debug/acpmux" \
  --out "$FAST_CHECKS_OUT/$TAG" --secs 180 --reads 24 "$@"
rc=$?; cat "$FAST_CHECKS_OUT/$TAG/summary.md" 2>/dev/null; exit $rc
