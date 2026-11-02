#!/usr/bin/env bash
# TEMPORARY: removed before landing. Runs the Script tests step N times and prints each failure's git stderr.
set -uo pipefail
cmds=$(awk '/name: Script tests \(pin-cmux-tui/{f=1} f&&/<<.CHECKS./{g=1;next} g&&/^ *CHECKS$/{exit} g' .github/workflows/cmux-next.yml)
echo "$(grep -vc '^ *#' <<<"$cmds") commands, $(getconf _NPROCESSORS_ONLN) cpus"
for i in $(seq 1 "${ROUNDS:-8}"); do
  log=$(mktemp)
  scripts/ci/run-checks-concurrently.sh <<<"$cmds" > "$log" 2>&1
  echo "== round $i: $(grep -c '^##\[group\].*failed (exit' "$log") failed"
  grep -E '^##\[group\].*failed \(exit' "$log" | sort -u
  grep -E -A8 '^git_q |line [0-9]+ exited' "$log" | head -60
  rm -f "$log"
done
