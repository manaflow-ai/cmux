#!/usr/bin/env bash
# The phases of a real acpmux daemon's restart (cmux-tui/crates/acpmux/tests/durable_agents/restart_reattach.rs
# `restart_phases`): ms from the spawn to the ready line, the first status, the first attach of a restored
# live chat and of a stored idle one, adoption done and startup done, over RUNS restarts (default 5) for each
# `HOSTED:IDLE` pair in CASES (default "1:0 10:0 100:0 0:100"). Run on the Linux pool:
#   cmux-ci test -- bash scripts/measure/acpmux-restart-phases.sh
# Prints the daemon's lines and a table of medians.
set -o pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root/cmux-tui" || exit 1
out=$(mktemp)
rc=0
for c in ${CASES:-1:0 10:0 100:0 0:100}; do
  ACPMUX_PHASES_HOSTED=${c%%:*} ACPMUX_PHASES_IDLE=${c##*:} ACPMUX_PHASES_RUNS=${RUNS:-5} \
    cargo test -p acpmux --test durable_agents restart_phases -- --ignored --nocapture 2>&1 \
    | tee -a "$out" | grep -E '^acpmux-restart-|test result|panicked|error(\[|:)'
  [ "${PIPESTATUS[0]}" = 0 ] || rc=1
done
python3 -I "$root/scripts/measure/acpmux-restart-phases.py" "$out"
rm -f "$out"
exit $rc
