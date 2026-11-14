#!/usr/bin/env bash
# Screen stream eval target: Sunshine (host, https://github.com/LizardByte/Sunshine) and Moonlight
# (viewer, https://github.com/moonlight-stream/moonlight-qt), each at its defaults, measured from
# outside with ../gui-viewer.sh, the same way as every other third-party viewer. Two Macs only
# (README.md, "Two Macs"): on one Mac the viewer would stream its own window back into itself.
#
# Needs, installed once by a person on the measure Macs (the target installs nothing):
# - the host Mac: `sunshine` on PATH or at /opt/homebrew/bin (brew install lizardbyte/homebrew/sunshine);
#   it captures and injects as a child of CmuxScreenEvalLauncher, so it shares that app's grants.
# - the viewer Mac: /Applications/Moonlight.app.
# Pairing is automatic: host-start writes a fresh PIN to the target's token file, which the harness
# hands to the viewer Mac (peer.py), and keeps offering it to Sunshine's API while the viewer runs
# `Moonlight pair`. Sunshine's state (its pairings, key and certificate) lives in the real home's
# ~/.cmux-screen-eval/sunshine, so a Mac pairs once, not every run.
set -euo pipefail
verb=$1
shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../gui-viewer.sh
source "$here/gui-viewer.sh"
moonlight=/Applications/Moonlight.app/Contents/MacOS/Moonlight
host=${EVAL_PEER:-127.0.0.1}
method="moonlight: cmux-rd observe through Moonlight's window (CGEventPostToPid to the ScreenCaptureKit frame where the marker changed); Sunshine and Moonlight expose no split"

real_home() { dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p'; }
sunshine_bin() { command -v sunshine 2>/dev/null || { [[ -x /opt/homebrew/bin/sunshine ]] && echo /opt/homebrew/bin/sunshine; }; }

host_start() {
  local bin dir pin pass
  bin=$(sunshine_bin) || { echo "moonlight: no sunshine on this Mac (brew install lizardbyte/homebrew/sunshine)" >&2; return 1; }
  dir="$(real_home)/.cmux-screen-eval/sunshine"
  mkdir -p "$dir"
  chmod 700 "$dir"
  # The API's login: made once, kept beside the state it guards.
  if [[ ! -s "$dir/api-pass" ]]; then
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$dir/api-pass"
    chmod 600 "$dir/api-pass"
  fi
  pass=$(cat "$dir/api-pass")
  cat >"$dir/sunshine.conf" <<EOF
sunshine_name = cmux-screen-eval
file_state = $dir/state.json
credentials_file = $dir/credentials.json
pkey = $dir/key.pem
cert = $dir/cert.pem
log_path = $EVAL_STATE/host.log
origin_web_ui_allowed = pc
EOF
  "$bin" "$dir/sunshine.conf" --creds eval "$pass" >"$EVAL_STATE/creds.log" 2>&1 || { echo "moonlight: sunshine --creds failed" >&2; return 1; }
  pin=$(python3 -I -c 'import secrets; print(f"{secrets.randbelow(10000):04d}")')
  printf '%s\n' "$pin" >"$EVAL_STATE/token"
  chmod 600 "$EVAL_STATE/token"
  : >"$EVAL_STATE/host.log"
  "$bin" "$dir/sunshine.conf" >>"$EVAL_STATE/host.out" 2>&1 &
  echo $! >"$EVAL_STATE/host.pid"
  for _ in $(seq 1 300); do
    if curl -sk -o /dev/null -u "eval:$pass" https://127.0.0.1:47990/api/apps; then
      # Offer the PIN while the host runs: Sunshine takes it only while a pair request is waiting,
      # and the viewer Mac sends that request at the start of each view verb (once paired, never).
      (while kill -0 "$(cat "$EVAL_STATE/host.pid")" 2>/dev/null; do
        curl -sk -o /dev/null -u "eval:$pass" -X POST https://127.0.0.1:47990/api/pin \
          -d "{\"pin\":\"$pin\",\"name\":\"cmux-screen-eval\"}" || true
        sleep 1 # the PIN offer's period, until host-stop
      done) &
      echo $! >"$EVAL_STATE/pin.pid"
      return 0
    fi
    kill -0 "$(cat "$EVAL_STATE/host.pid")" 2>/dev/null || break
    sleep 0.1 # bounded wait for Sunshine's API (30 s)
  done
  echo "moonlight: sunshine did not start" >&2
  tail -20 "$EVAL_STATE/host.out" "$EVAL_STATE/host.log" >&2 2>/dev/null
  return 1
}

stop_pid() {
  local file=$1 pid
  [[ -f "$file" ]] || return 0
  pid=$(cat "$file")
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1 # bounded wait for the process to exit (5 s)
  done
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$file"
}

# viewer_start: pair if needed, then stream the host's desktop full screen at Moonlight's defaults.
viewer_start() {
  [[ "$host" != 127.* && "$host" != localhost ]] || { echo "moonlight: needs a second Mac (lan= / viewer-of=)" >&2; return 1; }
  [[ -x "$moonlight" ]] || { echo "moonlight: no /Applications/Moonlight.app on the viewer Mac" >&2; return 1; }
  [[ -s "$EVAL_STATE/token" ]] || { echo "moonlight: no PIN from the host Mac" >&2; return 1; }
  # Already paired, it returns at once; else it waits for the host Mac's PIN offer (60 s at most).
  "$moonlight" pair "$host" --pin "$(cat "$EVAL_STATE/token")" >"$EVAL_STATE/pair.log" 2>&1 &
  echo $! >"$EVAL_STATE/pair.pid"
  for _ in $(seq 1 600); do
    kill -0 "$(cat "$EVAL_STATE/pair.pid")" 2>/dev/null || break
    sleep 0.1 # bounded wait for the pairing (60 s)
  done
  stop_pid "$EVAL_STATE/pair.pid"
  "$moonlight" stream "$host" Desktop --display-mode borderless >"$EVAL_STATE/viewer.log" 2>&1 &
  echo $! >"$EVAL_STATE/viewer.pid"
}

case "$verb" in
  build)
    gv_build
    ;;
  # The viewer Mac's half observes and captures the display, so it needs the launcher's grants.
  caps) echo viewer-grants ;;
  host-start) host_start ;;
  host-stop)
    stop_pid "$EVAL_STATE/pin.pid"
    stop_pid "$EVAL_STATE/host.pid"
    ;;
  latency-view)
    # latency-view INPUT SAMPLES RAW
    viewer_start || { printf '{"error":"viewer did not start"}\n' >"$3"; exit 1; }
    sleep 3 # Moonlight's stream starts and goes full screen before the locate
    rc=0
    gv_latency Moonlight "$1" "$2" "$3" || rc=$?
    stop_pid "$EVAL_STATE/viewer.pid"
    exit "$rc"
    ;;
  latency-report) gv_latency_report "$1" "$2" "$3" "$method" ;;
  window-view)
    # window-view SECONDS SNAPSHOT GO RAW
    viewer_start || { touch "$3"; exit 1; }
    rc=0
    gv_window_view Moonlight "$1" "$2" "$3" "$4" || rc=$?
    stop_pid "$EVAL_STATE/viewer.pid"
    exit "$rc"
    ;;
  window-report) gv_window_report "$1" "$2" ;;
  *) echo "moonlight.sh: unknown verb $verb" >&2; exit 2 ;;
esac
