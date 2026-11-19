#!/usr/bin/env bash
# The Linux target of the iPhone's live Screen Sharing leg (scripts/ci/ios-screen-share-live.sh): a Linux
# desktop host the phone opens through the device hub, on its own Linux step beside the phone's Mac
# simulator step. The two meet through the hub only: this step registers its desktop under NAME on the
# development hub as the step's agent session, and the phone (ScreenSharingLiveUITests with
# TEST_RUNNER_CMUX_SS_MAC=NAME) waits for that row to come online. Every event the desktop received is read
# back from `xinput test-xi2 --root` on its display (scripts/ci/ios_screen_share_live.py readback --target linux).
#
#   ios-screen-share-linux-host.sh selftest
#       No account, no hub: builds cmux-rd (the release features), starts Xvfb, logs `xinput test-xi2 --root`,
#       sends a click, a double-click, a right-click, a drag and "hello" through XTest (xdotool), and fails
#       unless the readback sees each one. Proves the host build, the display and the readback.
#   ios-screen-share-linux-host.sh host NAME [SECONDS]
#       The live host: the selftest's display and logger, then `cmux-rd linux-host enable` with an access
#       token minted from the step's own session (cmux-ci run --sign-in agent, $CMUX_CI_SIGNIN_FILE; never
#       printed) on the development hub, then `linux-host run` on that display for SECONDS (default 2400) or
#       until DONE events have arrived, then the readback. Fails when the readback fails.
#
# Output: artifacts/ios-screen-share-linux/ (xi2.txt, keymap.txt, readback.json, host.log, build.log,
# summary.json), and artifacts/ios-screen-share-linux.tgz of it.
set -uo pipefail
mode="${1:-}"
case "$mode" in selftest) ;; host) name="${2:?host NAME [SECONDS]}"; seconds="${3:-2400}" ;;
  *) echo "usage: ios-screen-share-linux-host.sh selftest | host NAME [SECONDS]" >&2; exit 2 ;; esac
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
out="$root/artifacts/ios-screen-share-linux"
work="$root/.build/ios-screen-share-linux"
rm -rf "$out" "$work"
mkdir -p "$out" "$work/home"
dev_hub=https://cmux-device-hub-dev.debussy.workers.dev
stack_api=https://api.stack-auth.com/api/v1
# The development Stack project the Debug iPhone signs in to (cmux-cloud-environment DEVELOPMENT_STACK_*; public).
stack_project=454ecd03-1db2-4050-845e-4ce5b0cd9895
stack_client_key=pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g
pids=()
status=0 reason=""
say() { printf '%s\n' "$*" | tee -a "$out/summary.txt"; }
fail() { status=1; reason="$1"; say "FAIL: $1"; }
finish() {
  local p
  for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
  rm -f "$work/token" 2>/dev/null || true
  python3 -I -c 'import json,sys; json.dump({"mode":sys.argv[1],"status":int(sys.argv[2]),"reason":sys.argv[3]},open(sys.argv[4],"w"),indent=2)' \
    "$mode" "$status" "$reason" "$out/summary.json" || true
  tar -czf "$root/artifacts/ios-screen-share-linux.tgz" -C "$root/artifacts" ios-screen-share-linux 2>/dev/null || true
  [[ -z "${FAST_CHECKS_OUT:-}" ]] || cp -R "$out" "$FAST_CHECKS_OUT/" 2>/dev/null || true
  exit "$status"
}
trap finish EXIT
trap 'exit 143' TERM

# --- tools: Xvfb, xinput, xdotool, xmodmap (Debian/Ubuntu names) ----------------------------------------------
need=()
command -v Xvfb >/dev/null || need+=(xvfb)
command -v xinput >/dev/null || need+=(xinput)
command -v xdotool >/dev/null || need+=(xdotool)
command -v xmodmap >/dev/null || need+=(x11-xserver-utils)
pkg-config --exists x11 xext xtst xfixes xdamage xrandr 2>/dev/null ||
  need+=(libx11-dev libxext-dev libxtst-dev libxfixes-dev libxdamage-dev libxrandr-dev)
command -v clang >/dev/null || need+=(clang libclang-dev)
command -v pkg-config >/dev/null || need+=(pkg-config)
if [[ ${#need[@]} -gt 0 ]]; then
  say "- installing: ${need[*]}"
  { sudo -n apt-get update -q && sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${need[@]}"; } \
    >"$work/apt.log" 2>&1 || { tail -20 "$work/apt.log"; fail "could not install ${need[*]}"; exit 1; }
fi

# --- cmux-rd, as cmux-rd-release.yml builds it -----------------------------------------------------------------
t0=$SECONDS
manifest=cmux-tui/crates/cmux-rd-host/Cargo.toml
cargo build --locked --release --manifest-path "$manifest" --no-default-features --features openh264,link \
  --bin cmux-rd >"$out/build.log" 2>&1 || { tail -40 "$out/build.log"; fail "cmux-rd did not build"; exit 1; }
target_dir="$(cargo metadata --format-version 1 --no-deps --manifest-path "$manifest" |
  python3 -I -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
rd="$target_dir/release/cmux-rd"
[[ -x "$rd" ]] || { fail "no cmux-rd at $rd"; exit 1; }
say "- cmux-rd: built in $((SECONDS - t0)) s"
HOME="$work/home" "$rd" linux-host status --json >"$out/status-before.json" 2>&1 || true

# --- the display and its event log ----------------------------------------------------------------------------
display=""
for n in $(seq 140 199); do
  [[ -e "/tmp/.X11-unix/X$n" || -e "/tmp/.X$n-lock" ]] && continue
  display=":$n"; break
done
[[ -n "$display" ]] || { fail "no free X display between :140 and :199"; exit 1; }
Xvfb "$display" -screen 0 1280x800x24 -nolisten tcp >"$out/xvfb.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 50); do DISPLAY="$display" xdpyinfo >/dev/null 2>&1 && break
  DISPLAY="$display" xmodmap -pke >/dev/null 2>&1 && break; sleep 0.2; done
DISPLAY="$display" xmodmap -pke >"$out/keymap.txt" 2>/dev/null || { fail "Xvfb $display did not start"; exit 1; }
DISPLAY="$display" stdbuf -oL xinput test-xi2 --root >"$out/xi2.txt" 2>"$out/xinput.err" &
pids+=($!)
sleep 1
say "- display: Xvfb $display 1280x800, xinput test-xi2 --root logging"

readback() {
  python3 -I scripts/ci/ios_screen_share_live.py readback --target linux --events "$out/xi2.txt" \
    --keymap "$out/keymap.txt" --out "$out/readback.json"
}

if [[ "$mode" == selftest ]]; then
  # The phone's gestures as XTest input, the way cmux-rd's injection reaches the X server.
  x() { DISPLAY="$display" xdotool "$@"; }
  x mousemove 640 400 click 1; sleep 0.8
  x mousemove 640 400 click --repeat 2 --delay 90 1; sleep 0.8
  x mousemove 640 400 click 3; sleep 0.8
  x mousemove 600 400 mousedown 1
  for i in $(seq 1 25); do x mousemove $((600 + i * 6)) $((400 + i)); sleep 0.02; done
  x mouseup 1; sleep 0.5
  x type --delay 60 hello; sleep 1
  if readback >"$work/readback.txt"; then say "- readback: PASS $(cat "$work/readback.txt")"
  else fail "readback: $(cat "$work/readback.txt")"; fi
  exit "$status"
fi

# --- host: the step's session as an access token, enable, run --------------------------------------------------
[[ -n "${CMUX_CI_SIGNIN_FILE:-}" ]] || { fail "no sign-in session: send the step with cmux-ci run --sign-in agent"; exit 1; }
# shellcheck source=scripts/lib/fleet-signin-session.sh
source scripts/lib/fleet-signin-session.sh
cmux_fleet_signin_load || { fail "$CMUX_FLEET_SIGNIN_ERROR"; exit 1; }
umask 077
# Stack's refresh: the refresh token goes in a header from stdin-fed curl config, never on the command line.
printf 'header = "x-stack-refresh-token: %s"\n' "$_cmux_fleet_signin_token" | curl -fsS --retry 3 -X POST \
  -H "x-stack-project-id: $stack_project" -H "x-stack-access-type: client" \
  -H "x-stack-publishable-client-key: $stack_client_key" -H 'content-type: application/json' -d '{}' \
  -K - "$stack_api/auth/sessions/current/refresh" |
  python3 -I -c 'import json,sys; t=json.load(sys.stdin).get("access_token") or ""; sys.stdout.write(t); sys.exit(0 if t else 1)' \
  >"$work/token" || { cmux_fleet_signin_forget; fail "Stack refused the step's session refresh"; exit 1; }
cmux_fleet_signin_forget
HOME="$work/home" DISPLAY="$display" "$rd" linux-host enable --stack-token-file "$work/token" --hub "$dev_hub" \
  --name "$name" >"$out/enable.log" 2>&1 || { tail -20 "$out/enable.log"; fail "linux-host enable failed"; exit 1; }
rm -f "$work/token"
say "- host: enabled as '$name' on $dev_hub"
HOME="$work/home" DISPLAY="$display" "$rd" linux-host run --display "$display" --capture x11 >"$out/host.log" 2>&1 &
host=$!
pids+=("$host")
# Bounded: the phone's run ends with its close (step 12); the host stays up SECONDS at most, and ends early once
# the typed keys and a right-click are in the log and nothing new came for 60 s.
deadline=$((SECONDS + seconds)) last_size=-1 quiet_since=$SECONDS
while (( SECONDS < deadline )); do
  kill -0 "$host" 2>/dev/null || { fail "linux-host run ended ($(tail -3 "$out/host.log" | tr '\n' ' '))"; break; }
  size=$(wc -c <"$out/xi2.txt")
  [[ "$size" != "$last_size" ]] && { last_size=$size; quiet_since=$SECONDS; }
  if (( SECONDS - quiet_since > 60 )) && readback >/dev/null 2>&1; then break; fi
  sleep 5
done
HOME="$work/home" "$rd" linux-host share off >>"$out/host.log" 2>&1 || true
if [[ $status -eq 0 ]]; then
  if readback >"$work/readback.txt"; then say "- readback: PASS $(cat "$work/readback.txt")"
  else fail "readback: $(cat "$work/readback.txt")"; fi
fi
