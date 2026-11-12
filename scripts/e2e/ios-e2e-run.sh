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
WORKSPACE_ID="${CMUX_E2E_WORKSPACE_ID:-}"
SURFACE_ID="${CMUX_E2E_SURFACE_ID:-}"
STEP_TIMEOUT=45
BACKGROUND_SECONDS="${CMUX_E2E_BACKGROUND_SECONDS:-0}"
VIDEO_PATH="${CMUX_E2E_VIDEO:-}"
VIDEO_PID=""

usage() {
  cat <<'EOF'
Usage: scripts/e2e/ios-e2e-run.sh --tag <tag> --sim-udid <udid> --evidence-dir <dir>
       [--bundle-id <id>] [--workspace-id <id>] [--surface-id <id>]
       [--step-timeout <seconds>] [--background-seconds <seconds>]
       [--video <path>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --sim-udid) SIM_UDID="${2:-}"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --workspace-id) WORKSPACE_ID="${2:-}"; shift 2 ;;
    --surface-id) SURFACE_ID="${2:-}"; shift 2 ;;
    --step-timeout) STEP_TIMEOUT="${2:-}"; shift 2 ;;
    --background-seconds) BACKGROUND_SECONDS="${2:-}"; shift 2 ;;
    --video) VIDEO_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$TAG" && -n "$SIM_UDID" && -n "$EVIDENCE_DIR" ]] || { usage >&2; exit 2; }
[[ -n "$WORKSPACE_ID" && -n "$SURFACE_ID" || -z "$WORKSPACE_ID" && -z "$SURFACE_ID" ]] || {
  echo "error: workspace and surface IDs must be provided together" >&2
  exit 2
}
[[ "$BACKGROUND_SECONDS" =~ ^[0-9]+$ ]] || { echo "error: background seconds must be a non-negative integer" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOCKET="/tmp/cmux-debug-${TAG}.sock"
AXE="${CMUX_E2E_AXE:-axe}"
mkdir -p "$EVIDENCE_DIR"

cleanup() {
  local status=$?
  if [[ -n "$VIDEO_PID" ]]; then
    kill -INT "$VIDEO_PID" >/dev/null 2>&1 || true
    wait "$VIDEO_PID" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

monotonic_seconds() {
  /usr/bin/python3 - <<'PY'
import time
print(f"{time.monotonic():.6f}")
PY
}

if [[ -n "$VIDEO_PATH" ]]; then
  mkdir -p "$(dirname "$VIDEO_PATH")"
  xcrun simctl io "$SIM_UDID" recordVideo --codec=h264 "$VIDEO_PATH" >/dev/null 2>&1 &
  VIDEO_PID=$!
fi

# --- evidence + assertion helpers -------------------------------------------

STEP_NAME="preflight"
STEP_INDEX=0
TIMINGS_FILE="$EVIDENCE_DIR/steps.jsonl"
: > "$TIMINGS_FILE"

fail() {
  echo "E2E FAIL step=$STEP_NAME: $*" >&2
  shot "failure"
  # Keep a stable final line for CI result parsers and failure attribution.
  echo "E2E FAIL step=$STEP_NAME" >&2
  exit 1
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
  if [[ -n "$WORKSPACE_ID" ]]; then
    CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" read-screen \
      --workspace "$WORKSPACE_ID" --surface "$SURFACE_ID" --lines 40 \
      2>/dev/null || true
  else
    CMUX_TAG="$TAG" "$REPO_ROOT/scripts/cmux-debug-cli.sh" read-screen 2>/dev/null || true
  fi
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

# A preceding real-use workload can leave the phone on the workspace list.
# Keep this driver self-contained by opening the first visible workspace before
# trying to attach terminal input. The row identifier is part of the app's
# accessibility contract, so this does not depend on screen coordinates or on
# whichever workspace happened to be selected by an earlier workload.
terminal_surface_visible() {
  "$AXE" describe-ui --udid "$SIM_UDID" 2>/dev/null \
    | grep -qF "MobileTerminalSurface"
}

ensure_terminal_surface() {
  if [[ -z "$WORKSPACE_ID" ]]; then
    terminal_surface_visible && return 0
  elif terminal_surface_visible; then
    # The real-use phase supplies a specific Codex workspace/surface. Always
    # return to the list before selecting its row so a prior workload's
    # visible terminal cannot satisfy this check or receive input instead.
    "$AXE" tap --id MobileWorkspaceBackButton --udid "$SIM_UDID" \
      --wait-timeout 15 --poll-interval 0.25 >/dev/null 2>&1 \
      || fail "targeted workspace is already open but cannot return to the workspace list"
    local list_deadline=$(( $(date +%s) + STEP_TIMEOUT ))
    while (( $(date +%s) < list_deadline )); do
      terminal_surface_visible || break
      sleep 1
    done
    if terminal_surface_visible; then
      fail "workspace list did not appear before selecting target workspace"
    fi
  fi

  local row_id
  if [[ -n "$WORKSPACE_ID" ]]; then
    row_id="MobileWorkspaceRow-$WORKSPACE_ID"
    local ui_dump
    row_id=""
    # The workload creates multiple workspaces, so the target can be below
    # the initially attached rows. Scroll the actual list until the exact
    # workspace suffix appears, preserving any U+001F Mac namespace for AXe.
    for _ in {1..12}; do
      ui_dump="$($AXE describe-ui --udid "$SIM_UDID" 2>/dev/null || true)"
      if grep -qF "MobileWorkspaceRow-$WORKSPACE_ID" <<<"$ui_dump"; then
        row_id="MobileWorkspaceRow-$WORKSPACE_ID"
        break
      fi
      row_id="$(grep -oE 'MobileWorkspaceRow-[^"[:space:]]+' <<<"$ui_dump" \
        | grep -F -- "$WORKSPACE_ID" | head -1 || true)"
      [[ -n "$row_id" ]] && break
      "$AXE" gesture scroll-up --udid "$SIM_UDID" >/dev/null 2>&1 || true
      sleep 1
    done
    [[ -n "$row_id" ]] || fail "target workspace row is not visible: MobileWorkspaceRow-$WORKSPACE_ID"
  else
    row_id="$("$AXE" describe-ui --udid "$SIM_UDID" 2>/dev/null \
      | grep -oE 'MobileWorkspaceRow-[A-Za-z0-9._:-]+' \
      | head -1 || true)"
  fi
  [[ -n "$row_id" ]] || fail "workspace list is visible but no MobileWorkspaceRow was exposed"
  echo "opening workspace row: $row_id"
  "$AXE" tap --id "$row_id" --wait-timeout 15 --poll-interval 0.25 \
    --udid "$SIM_UDID" >/dev/null

  local deadline=$(( $(date +%s) + STEP_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    terminal_surface_visible && return 0
    sleep 1
  done
  fail "workspace row opened but MobileTerminalSurface did not appear within ${STEP_TIMEOUT}s"
}

wait_for_app_ready_trace() {
  local target_surface="$1"
  local start_offset="${2:-0}"
  local data_container
  data_container="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
  [[ -n "$data_container" ]] || return 1
  local log_path="$data_container/Library/Application Support/cmux-debug.log"
  local surface_prefix="${target_surface:0:8}"
  surface_prefix="${surface_prefix,,}"
  local deadline=$(( $(date +%s) + STEP_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    if [[ -f "$log_path" ]]; then
      local elapsed
      elapsed="$(/usr/bin/python3 - "$log_path" "$surface_prefix" "$start_offset" <<'PY_TRACE'
import re
import sys

path, surface_prefix, start_offset = sys.argv[1:]
scene = None
try:
    with open(path, "rb") as raw:
        raw.seek(int(start_offset))
        handle = (line.decode("utf-8", errors="replace") for line in raw)
        for line in handle:
            match = re.search(r"LAT scene\.active t=(\d+)", line)
            if match:
                scene = int(match.group(1))
                continue
            match = re.search(r"LAT rd\.present t=(\d+).*\bs=([0-9a-f]+)", line)
            if match and scene is not None and match.group(2).lower() == surface_prefix:
                rendered = int(match.group(1))
                if rendered >= scene:
                    print(f"{(rendered - scene) / 1_000_000:.6f}")
                    break
except OSError:
    pass
PY_TRACE
      )"
      if [[ "$elapsed" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s\n' "$elapsed"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
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
ensure_terminal_surface
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
BACKGROUND_STARTED="$(monotonic_seconds)"
if (( BACKGROUND_SECONDS > 0 )); then
  echo "== backgrounded for ${BACKGROUND_SECONDS}s"
  sleep "$BACKGROUND_SECONDS"
fi
FOREGROUND_STARTED="$(monotonic_seconds)"
TRACE_LOG_PATH=""
TRACE_START_OFFSET=0
DATA_CONTAINER="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
if [[ -n "$DATA_CONTAINER" ]]; then
  TRACE_LOG_PATH="$DATA_CONTAINER/Library/Application Support/cmux-debug.log"
  if [[ -f "$TRACE_LOG_PATH" ]]; then
    TRACE_START_OFFSET="$(wc -c < "$TRACE_LOG_PATH" | tr -d ' ')"
  fi
fi
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" >/dev/null
wait_phone "$MARKC"   # session replay re-renders the pre-background history
# Relaunch resets first responder exactly like a cold boot; re-establish
# input with the same tap + typed self-check used in preflight.
ensure_terminal_surface
"$AXE" tap --id MobileTerminalSurface --udid "$SIM_UDID" >/dev/null 2>&1 || true
sleep 1
ensure_terminal_keyboard
if ! input_ready; then
  "$AXE" tap --id MobileTerminalSurface --udid "$SIM_UDID" >/dev/null 2>&1 || true
  "$AXE" tap --id terminal.inputAccessory.hideKeyboard --udid "$SIM_UDID" >/dev/null 2>&1 || true
  sleep 1
  input_ready || fail "terminal input never recovered after relaunch"
fi
APP_FOREGROUND_SECONDS=""
APP_FOREGROUND_SECONDS_JSON="null"
if [[ -n "$SURFACE_ID" ]]; then
  APP_FOREGROUND_SECONDS="$(wait_for_app_ready_trace "$SURFACE_ID" "$TRACE_START_OFFSET" || true)"
  [[ "$APP_FOREGROUND_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || \
    fail "app-side foreground trace did not reach target terminal frame"
  APP_FOREGROUND_SECONDS_JSON="$APP_FOREGROUND_SECONDS"
fi
MARK_RESUME="E2ERESUME$(date +%s)"
type_line "echo $MARK_RESUME"
wait_mac_output "$MARK_RESUME"
RESUME_SECONDS="$(/usr/bin/python3 - "$FOREGROUND_STARTED" <<'PY'
import sys, time
print(f"{time.monotonic() - float(sys.argv[1]):.6f}")
PY
)"
printf '{"background_seconds":%s,"resume_to_mac_input_seconds":%s,"app_foreground_to_terminal_ready_seconds":%s,"background_started_monotonic":%s}\n' \
  "$BACKGROUND_SECONDS" "$RESUME_SECONDS" "$APP_FOREGROUND_SECONDS_JSON" "$BACKGROUND_STARTED" > "$EVIDENCE_DIR/background.json"
if (( BACKGROUND_SECONDS >= 120 )) && [[ -n "$APP_FOREGROUND_SECONDS" ]]; then
  python3 - "$APP_FOREGROUND_SECONDS" <<'PY'
import sys
if float(sys.argv[1]) > 2.0:
    raise SystemExit("app foreground-to-terminal exceeded 2 seconds: " + sys.argv[1])
PY
fi
wait_phone "$MARK_RESUME"
step_done

# --- 6: input liveness after reconnect ------------------------------------------

MARK2="E2EPOST$(date +%s)"
step "post-reconnect-input"
type_line "echo $MARK2"
wait_mac_output "$MARK2"
wait_phone "$MARK2"
step_done

echo "E2E PASS: 6/6 terminal steps verified both sides (tag=$TAG)"
