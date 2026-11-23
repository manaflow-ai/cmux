#!/usr/bin/env bash
# How the iPhone app moves when the system keyboard shows, hides or is dragged
# down (Leo, 2026-11-21: "the 'animation' for when the built in keyboard
# collapses and things shrink is not fast enough. percieved time and time to
# interactive are not prioritized enough.").
#
#   cmux-ci run --class simulator --label measure --script scripts/measure/ios-keyboard-motion.sh \
#     --ref SHA --artifact .build/ios-keyboard-motion/report.json --timeout 7200
#
# Runs KeyboardMotionBenchUITests (cmux-next-ios/UITests) through
# scripts/ci/cmux-next-ios-sim.sh `test ui=`, on one iPhone simulator, with the
# app's keyboard-pin trace on. Per surface (terminal shell, vim in the terminal,
# agent chat composer, Chief composer, the workspace search field) it shows and
# hides the keyboard 5 times by tap, 5 times by the key row's keyboard key where
# there is one, drags it down 3 times, and 3 times each measures the time to the
# first touch the app takes after a hide and the first key after a show. Then
# ios_keyboard_motion.py reads the trace and the test's step marks and writes
# .build/ios-keyboard-motion/report.json (metrics: see its docstring), plus the
# per-surface traces beside it. A failed UI test still gets a report of what it
# traced; the step's exit is the UI run's.
#
# At a commit not yet on feat-cmux-next or main (a pull request's head) the controller runs only
# listed measure scripts, so run the UI suite through the CI script and read it here:
#
#   cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg test \
#     --arg ui=KeyboardMotionBenchUITests --artifact artifacts/ios-sim/evidence.zip --timeout 7200
#   cmux-ci artifact STEP /tmp/kbm/evidence.zip   # --failed when a UI test failed
#   unzip -q /tmp/kbm/evidence.zip -d /tmp/kbm/evidence
#   python3 -I scripts/measure/ios_keyboard_motion.py --console /tmp/kbm/evidence/ui-console.txt \
#     --attachments /tmp/kbm/evidence/ui-attachments --out .build/ios-keyboard-motion/report.json
#
# Args: ui=SUITE (default KeyboardMotionBenchUITests), only=TEST,... (methods of
# it, e.g. only=testTerminalShell).
set -euo pipefail
trap 'echo "ios-keyboard-motion.sh: line $LINENO exited $? ($BASH_COMMAND)" >&2' ERR

# shellcheck source-path=SCRIPTDIR source=../cmux-next/lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet ios-keyboard-motion.sh "xcodebuild and an iOS simulator" "none (a measurement)" \
  "cmux-ci run --class simulator --label measure --script scripts/measure/ios-keyboard-motion.sh --ref SHA --artifact .build/ios-keyboard-motion/report.json"

suite=KeyboardMotionBenchUITests only=""
for kv in "$@"; do
  case "$kv" in
    ui=*) suite="${kv#*=}" ;;
    only=*) only="${kv#*=}" ;;
    *) echo "ios-keyboard-motion.sh: unknown arg '$kv' (ui=, only=)" >&2; exit 2 ;;
  esac
done
[[ "$suite" =~ ^[A-Za-z0-9_]+$ ]] || { echo "ios-keyboard-motion.sh: ui= wants one suite name, got '$suite'" >&2; exit 2; }
[[ -z "$only" || "$only" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] ||
  { echo "ios-keyboard-motion.sh: only= wants test method names, got '$only'" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
out="$root/.build/ios-keyboard-motion"
rm -rf "$out" && mkdir -p "$out"

sel="$suite"
if [[ -n "$only" ]]; then
  sel=""
  IFS=',' read -r -a methods <<< "$only"
  for m in "${methods[@]}"; do sel="${sel:+$sel,}$suite/$m"; done
fi

set +e
bash scripts/ci/cmux-next-ios-sim.sh test "ui=$sel"
ui_status=$?
set -e
echo "ios-keyboard-motion.sh: the UI run exited $ui_status"

sim="$root/artifacts/ios-sim"
for f in SUMMARY.md ui-tests.json ui-tests-failures.txt ui-console.txt; do
  [[ -f "$sim/$f" ]] && cp "$sim/$f" "$out/" || true
done
if [[ ! -s "$sim/ui-console.txt" ]]; then
  echo "ios-keyboard-motion.sh: no UI test console log at $sim/ui-console.txt; nothing to read" >&2
  printf '{"schema":"cmux-mobile-bench/keyboard-motion/v1","error":"no UI test console log","ui_exit":%d,"surfaces":{}}\n' \
    "$ui_status" > "$out/report.json"
  exit "$(( ui_status == 0 ? 1 : ui_status ))"
fi
python3 -I scripts/measure/ios_keyboard_motion.py --console "$sim/ui-console.txt" \
  --attachments "$sim/ui-attachments" --traces "$out/traces" --out "$out/report.json" \
  --meta "sha=$(git rev-parse HEAD)" --meta "suite=$sel" --meta "ui_exit=$ui_status" \
  --meta "worker=${CMUX_CI_WORKER:-$(hostname -s)}" --meta "runtime=${CMUX_CI_IOS_SIM_RUNTIME:-default}"
exit "$ui_status"
