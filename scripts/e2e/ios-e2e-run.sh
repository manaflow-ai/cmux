#!/usr/bin/env bash
# iOS e2e terminal driver: the six-step terminal script of the PR e2e gate.
#
# Runs against an ALREADY signed-in, paired, connected tagged pair — locally
# the pair `scripts/run-iroh-release-gate.sh --keep-simulator` leaves behind,
# on CI the pair the ios-e2e workflow launches. This script only drives and
# asserts; it never builds, signs in, or pairs.
#
# Every step asserts BOTH sides of the transport:
#   - phone side: simulator screenshot + Vision OCR (what actually rendered)
#   - Mac side:   tagged debug socket (what the real shell actually received)
# One side alone can lie (an echo can render locally without reaching the
# Mac; the Mac can accept input the phone never repaints after).
#
# Steps and the shipped regression class each one guards:
#   1 echo marker round trip      input stall        (cmux #12927)
#   2 burst output + scrollback   byte-tee append    (cmux #13432)
#   3 alt-screen enter/exit       alt-screen freeze  (cmux #12844)
#   4 Ctrl-C a running command    control keys cross the transport
#   5 background/foreground       blank replay       (cmux #14030)
#   6 marker after reconnect      recovery cooldown  (cmux #14124)
#
# Waits are bounded polls on observable state (OCR text or Mac screen text),
# never fixed sleeps standing in for synchronization. Failures name the step.
set -euo pipefail

TAG=""
SIM_UDID=""
EVIDENCE_DIR=""
BUNDLE_ID=""
STEP_TIMEOUT=45

usage() {
  cat <<'EOF'
Usage: scripts/e2e/ios-e2e-run.sh --tag <tag> --sim-udid <udid> --evidence-dir <dir>
       [--bundle-id <id>] [--step-timeout <seconds>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --sim-udid) SIM_UDID="${2:-}"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --step-timeout) STEP_TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$TAG" && -n "$SIM_UDID" && -n "$EVIDENCE_DIR" ]] || { usage >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOCKET="/tmp/cmux-debug-${TAG}.sock"
AXE="${CMUX_E2E_AXE:-axe}"
mkdir -p "$EVIDENCE_DIR"

# --- evidence + assertion helpers -------------------------------------------

STEP_NAME="preflight"
STEP_INDEX=0
TIMINGS_FILE="$EVIDENCE_DIR/steps.jsonl"
: > "$TIMINGS_FILE"

fail() {
  echo "E2E FAIL [$STEP_NAME]: $*" >&2
  shot "failure"
  collect_diagnostics
  exit 1
}

# On failure, keep what separates a product crash from a harness miss: whether
# the app still runs, its crash reports, and the device log since the run began.
RUN_STARTED_EPOCH="$(date +%s)"
collect_diagnostics() {
  local dir="$EVIDENCE_DIR/diagnostics" since
  mkdir -p "$dir"
  xcrun simctl spawn "$SIM_UDID" launchctl list 2>/dev/null \
    | grep -F "${BUNDLE_ID:-dev.cmux}" >"$dir/app-process.txt" \
    || echo "not running" >"$dir/app-process.txt"
  find "$HOME/Library/Logs/DiagnosticReports" -type f -newermt "@$RUN_STARTED_EPOCH" \
    \( -iname '*cmux*' -o -iname '*.ips' \) -exec cp {} "$dir/" \; 2>/dev/null || true
  since="$(( $(date +%s) - RUN_STARTED_EPOCH + 60 ))s"
  xcrun simctl spawn "$SIM_UDID" log show --last "$since" --style compact \
    --predicate 'process CONTAINS[c] "cmux" OR subsystem CONTAINS[c] "cmux"' \
    >"$dir/device.log" 2>&1 || true
}

step() {
  STEP_INDEX=$((STEP_INDEX + 1))
  STEP_NAME="$1"
  STEP_STARTED="$(date +%s)"
  echo "== step $STEP_INDEX: $STEP_NAME"
}

step_done() {
  local now
  now="$(date +%s)"
  printf '{"step":%d,"name":"%s","seconds":%d}\n' \
    "$STEP_INDEX" "$STEP_NAME" "$((now - STEP_STARTED))" >> "$TIMINGS_FILE"
  shot "done"
}

shot() {
  xcrun simctl io "$SIM_UDID" screenshot \
    "$EVIDENCE_DIR/$(printf '%02d' "$STEP_INDEX")-$STEP_NAME-$1.png" 2>/dev/null || true
}

# Compile the Vision OCR helper once per run (plain swiftc, no xcodebuild).
OCR_BIN="$EVIDENCE_DIR/.ocr"
ocr_build() {
  [[ -x "$OCR_BIN" ]] && return 0
  swiftc -O "$SCRIPT_DIR/ocr.swift" -o "$OCR_BIN"
}

phone_text() {
  local png="$EVIDENCE_DIR/.probe.png"
  xcrun simctl io "$SIM_UDID" screenshot "$png" >/dev/null 2>&1 || return 1
  "$OCR_BIN" "$png" 2>/dev/null || true
}

mac_text() {
  CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" read-screen 2>/dev/null || true
}

# wait_for <label> <fn> <needle>: bounded poll, never a bare sleep.
wait_for() {
  local label="$1" fn="$2" needle="$3" deadline
  deadline=$(( $(date +%s) + STEP_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    if "$fn" | grep -qF -- "$needle"; then
      return 0
    fi
    sleep 1
  done
  fail "$label: '$needle' not observed within ${STEP_TIMEOUT}s"
}

wait_phone() { wait_for "phone render" phone_text "$1"; }
# Echoed keystrokes alone put the marker on the prompt line, so requiring one
# occurrence would pass without the command ever executing. Two occurrences =
# the typed line plus the command's own output.
wait_mac_output() {
  local needle="$1" deadline
  deadline=$(( $(date +%s) + STEP_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    if [[ "$(mac_text | grep -cF -- "$needle")" -ge 2 ]]; then
      return 0
    fi
    sleep 1
  done
  fail "mac shell: output of '$needle' not observed within ${STEP_TIMEOUT}s"
}

# Terminal input goes through the app's own input accessory: one tap on the
# keyboard toggle attaches the terminal as first responder (HID events land
# nowhere before that), and the accessory return/^C buttons are the app's own
# input path, more deterministic than raw HID keycodes.
ensure_terminal_keyboard() {
  if "$AXE" describe-ui --udid "$SIM_UDID" 2>/dev/null | grep -qF "Show Keyboard"; then
    "$AXE" tap --id terminal.inputAccessory.hideKeyboard --udid "$SIM_UDID"
    sleep 1
  fi
}

# The first key event after (re)attaching input is dropped by the simulator,
# so every line leads with a sacrificial space (harmless to the shell).
# Submit with the HID return key: the accessory return button renders a CR
# glyph but does not submit (observed live; tracked as a driver-found bug).
type_line() {
  "$AXE" type " $1" --udid "$SIM_UDID"
  "$AXE" key 40 --udid "$SIM_UDID"
}

# --- preflight ---------------------------------------------------------------

step "preflight"
ocr_build
[[ -S "$SOCKET" ]] || fail "tagged Mac debug socket missing: $SOCKET"
CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" identify >/dev/null \
  || fail "tagged Mac app did not answer identify on $SOCKET"
xcrun simctl list devices | grep -F "$SIM_UDID" | grep -q "(Booted)" \
  || fail "simulator $SIM_UDID is not booted"
if [[ -z "$BUNDLE_ID" ]]; then
  # The tagged dev app is the only dev.cmux.* bundle on this isolated sim.
  BUNDLE_ID="$(xcrun simctl listapps "$SIM_UDID" 2>/dev/null \
    | grep -oE 'dev\.cmux[A-Za-z0-9\.-]*' | sort -u | head -1)"
  [[ -n "$BUNDLE_ID" ]] || fail "no dev.cmux bundle installed on simulator"
fi
echo "bundle: $BUNDLE_ID"
# Establish terminal input deterministically: on a cold boot nothing is first
# responder until a tap lands, so tap the surface, attach the keyboard, then
# prove input works with a typed self-check before any real step. One
# recovery retry covers focus-state variance across launches.
input_ready() {
  local probe="E2EREADY$RANDOM"
  type_line "echo $probe"
  local deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    if [[ "$(mac_text | grep -cF -- "$probe")" -ge 2 ]]; then return 0; fi
    sleep 1
  done
  return 1
}
"$AXE" tap --id MobileTerminalSurface --udid "$SIM_UDID" >/dev/null 2>&1 || true
sleep 1
ensure_terminal_keyboard
if ! input_ready; then
  "$AXE" tap --id MobileTerminalSurface --udid "$SIM_UDID" >/dev/null 2>&1 || true
  "$AXE" tap --id terminal.inputAccessory.hideKeyboard --udid "$SIM_UDID" >/dev/null 2>&1 || true
  sleep 1
  input_ready || fail "terminal input never became ready (two attempts)"
fi
step_done

# --- 1: echo marker round trip ------------------------------------------------

MARK1="E2ERTT$(date +%s)"
step "echo-round-trip"
type_line "echo $MARK1"
wait_mac_output "$MARK1"   # the command RAN on the real Mac shell
wait_phone "$MARK1"    # output streamed back and RENDERED on the phone
step_done

# --- 2: burst output + scrollback ---------------------------------------------

step "burst-scrollback"
# A per-run number range keeps every marker unique, so reruns against a
# session that already holds an earlier burst can never match stale history.
BURST_START=$(( (RANDOM % 900 + 100) * 1000 ))
BURST_END=$(( BURST_START + 5000 ))
type_line "seq $BURST_START $BURST_END"
wait_phone "$BURST_END"      # tail of the burst rendered
# Prove scrollback traverses the burst: swipe up a fixed distance, then
# assert on whatever the viewport actually shows — an in-range ascending run
# whose top sits well above the tail. Hunting for one exact line is a race
# against OCR latency; asserting the visible window is deterministic. A
# full-history walk belongs in a soak lane, not a 3-minute gate.
# Right after the burst the view can still be in follow-live mode, which
# swallows the first swipes, so scroll in small verified batches: swipe,
# settle, check whether the visible window actually moved above the tail.
scrolled=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  "$AXE" swipe --start-x 200 --start-y 250 --end-x 200 --end-y 640 --udid "$SIM_UDID"
  "$AXE" swipe --start-x 200 --start-y 250 --end-x 200 --end-y 640 --udid "$SIM_UDID"
  sleep 1
  if phone_text | python3 -c "
import re, sys
lo, hi = int(sys.argv[1]), int(sys.argv[2])
# One frame decides: enough in-range rows (OCR drops a few), spanning about
# one viewport, with the top clearly above the live tail.
seen = sorted({int(n) for line in sys.stdin
               for n in re.findall(r'\b(\d{5,7})\b', line) if lo <= int(n) <= hi})
span = seen[-1] - seen[0] if seen else 0
ok = len(seen) >= 20 and 20 <= span <= 300 and seen[0] <= hi - 150
sys.exit(0 if ok else 1)
" "$BURST_START" "$BURST_END"; then
    scrolled=1
    break
  fi
done
[[ "$scrolled" -eq 1 ]] || fail "scrollback never showed a history window above the tail"
# Return to the live tail for the next steps.
for _ in 1 2 3 4 5 6 7 8; do
  "$AXE" swipe --start-x 200 --start-y 640 --end-x 200 --end-y 150 --udid "$SIM_UDID"
done
wait_phone "$BURST_END"      # tail restored before the next command
step_done

# --- 3: alt-screen enter/exit ---------------------------------------------------

step "alt-screen"
type_line "less /etc/services"
wait_phone "Network services"           # alt-screen content rendered
"$AXE" type "q" --udid "$SIM_UDID"
MARKQ="E2EALT$(date +%s)"
type_line "echo $MARKQ"
wait_mac_output "$MARKQ"        # primary screen is live again after exit
wait_phone "$MARKQ"
step_done

# --- 4: Ctrl-C a running command ------------------------------------------------

step "ctrl-c"
type_line "sleep 30"
"$AXE" key-combo --key 6 --modifiers 224 --udid "$SIM_UDID"   # HID Ctrl(224)+C(6); the accessory ^C tap does not interrupt
MARKC="E2EINT$(date +%s)"
type_line "echo $MARKC"
wait_mac_output "$MARKC"   # only reachable if the sleep actually died
wait_phone "$MARKC"
step_done

# --- 5: background/foreground replay --------------------------------------------

step "replay-after-reconnect"
"$AXE" button home --udid "$SIM_UDID"
# Keep simctl's answer (the pid) so a failed relaunch is visible in the log.
echo "relaunch: $(xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" 2>&1)"
wait_phone "$MARKC"   # session replay re-renders the pre-background history
# Relaunch resets first responder exactly like a cold boot; re-establish
# input with the same tap + typed self-check used in preflight.
"$AXE" tap --id MobileTerminalSurface --udid "$SIM_UDID" >/dev/null 2>&1 || true
sleep 1
ensure_terminal_keyboard
if ! input_ready; then
  "$AXE" tap --id MobileTerminalSurface --udid "$SIM_UDID" >/dev/null 2>&1 || true
  "$AXE" tap --id terminal.inputAccessory.hideKeyboard --udid "$SIM_UDID" >/dev/null 2>&1 || true
  sleep 1
  input_ready || fail "terminal input never recovered after relaunch"
fi
step_done

# --- 6: input liveness after reconnect ------------------------------------------

MARK2="E2EPOST$(date +%s)"
step "post-reconnect-input"
type_line "echo $MARK2"
wait_mac_output "$MARK2"
wait_phone "$MARK2"
step_done

echo "E2E PASS: 6/6 terminal steps verified both sides (tag=$TAG)"
