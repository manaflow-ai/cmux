#!/bin/bash
# mac-holds.sh never configures a dummynet pipe under 1 ms (a zero-delay pipe panicked a macOS fleet Mac).
#   bash test-mac-holds.sh [PATH/TO/mac-holds.sh]
# No root, no dnctl: MAC_HOLDS_DNCTL points at a stub that only records its arguments. Runs on Linux too.
set -u
SCRIPT=${1:-$(dirname "$0")/mac-holds.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\necho "$*" >> "%s/dnctl.log"\n' "$T" > "$T/dnctl"; chmod 755 "$T/dnctl"
export MAC_HOLDS_DNCTL="$T/dnctl" MAC_HOLDS_PY=${MAC_HOLDS_PY:-$(command -v python3)}
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
reset() { : > "$T/dnctl.log"; }

grep -q '^BASE_DELAY_MS=4$' "$SCRIPT"; rc=$?; check "the base delay is the named constant 4" '[ $rc -eq 0 ]'
grep -q 'pipe_config "$BASE_DELAY_MS"' "$SCRIPT"; rc=$?; check "start configures the pipe through pipe_config" '[ $rc -eq 0 ]'

for d in 0 00 -1 x ""; do
  reset; bash "$SCRIPT" _pipe_config "$d" 0 2> "$T/err"; rc=$?
  check "pipe_config refuses delay '$d'" '[ $rc -ne 0 ] && [ ! -s "$T/dnctl.log" ] && grep -q refusing "$T/err"'
done
reset; bash "$SCRIPT" _pipe_config 4 0.02; rc=$?
check "pipe_config applies delay 4" '[ $rc -eq 0 ] && grep -qx "pipe 7730 config delay 4 plr 0.02" "$T/dnctl.log"'

echo '{"start_s": 0.0, "hold_ms": 20.0, "kind": "short"}' > "$T/sched.jsonl"
reset; bash "$SCRIPT" _hold_loop 0 "$T/sched.jsonl" "$T/out.jsonl" 0.05 0 2> "$T/err"; rc=$?
check "the hold loop stops at a delay under 1 ms" \
  '[ $rc -ne 0 ] && ! grep -qE "delay (0|-[0-9]+) " "$T/dnctl.log" && grep -q refusing "$T/err"'
reset; bash "$SCRIPT" _hold_loop 0 "$T/sched.jsonl" "$T/out.jsonl" 0.05 4; rc=$?
check "the hold loop steps 24, 14 then back to 4" \
  '[ $rc -eq 0 ] && [ "$(cut -d" " -f5 "$T/dnctl.log" | tr "\n" " ")" = "24 14 4 " ]'

out=$(bash "$SCRIPT" _plr_of wifi-loss-1); check "wifi-loss-1 drops 1% at random" '[ "$out" = 0.01 ]'
out=$(bash "$SCRIPT" _plr_of wifi-loss); check "wifi-loss still drops 2%" '[ "$out" = 0.02 ]'
out=$(bash "$SCRIPT" schedule wifi-loss-1 60); rc=$?; check "wifi-loss-1 is a known profile with no holds" '[ $rc -eq 0 ] && [ -z "$out" ]'
[ "$fails" -eq 0 ] && echo "mac-holds: all passed" || { echo "mac-holds: $fails failed"; exit 1; }
