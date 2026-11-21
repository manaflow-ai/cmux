#!/bin/zsh
# A host-Mac test rig for comparing remote desktop engines on one display. Start it once
# from a terminal inside an app that holds Screen Recording and Accessibility (for example
# cmux): every host it starts inherits both grants, so a test never shows a permission prompt.
#   zsh mac-rig.sh [ROOT]        ROOT defaults to ~/cmux-rd-test; binaries in ROOT/bin
# It then takes one command per line from the FIFO ROOT/ctl (mode 0600) and nothing else:
#   rd | rd-motion          the cmux.rd/1 host (mac-host-run.sh) and the marker
#                           (more host flags: STATE/host-flags, see mac-host-run.sh)
#   webrtc | webrtc-motion  the WebRTC host (bin/webrtc/cmux-vnc-host --capture) and the marker
#   stop                    stop every host and the marker
#   quit                    stop, remove the FIFO and exit
# "-motion" animates the rest of the display under the marker. Logs and the token or pairing
# (secrets) stay in ROOT/state (0700).
set -u
root=${1:-$HOME/cmux-rd-test}
bin=$root/bin state=$root/state ctl=$root/ctl
mkdir -p "$state" && chmod 700 "$root" "$state"
[[ -p $ctl ]] || mkfifo -m 600 "$ctl"

stop_all() {
  for f in "$state"/*.pid(N); do kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; done
}
start_webrtc() {
  "$bin/cmux-rd-marker" "$@" > "$state/marker.log" 2>&1 &
  echo $! > "$state/marker.pid"
  # Its pairing (a secret) goes to a home of its own inside the state directory.
  mkdir -p "$state/webrtc-home"
  CFFIXED_USER_HOME="$state/webrtc-home" HOME="$state/webrtc-home" \
    "$bin/webrtc/cmux-vnc-host" --capture --name "rd comparison host" > "$state/webrtc.log" 2>&1 &
  echo $! > "$state/webrtc.pid"
}
trap 'stop_all; rm -f "$ctl"; exit 0' INT TERM HUP

echo "rig ready: echo rd|rd-motion|webrtc|webrtc-motion|stop|quit > $ctl"
while true; do
  while read -r cmd; do
    case $cmd in
      rd) stop_all; zsh "$bin/mac-host-run.sh" "$bin" "$state" ;;
      rd-motion) stop_all; zsh "$bin/mac-host-run.sh" "$bin" "$state" --motion ;;
      webrtc) stop_all; start_webrtc ;;
      webrtc-motion) stop_all; start_webrtc --motion ;;
      stop) stop_all ;;
      quit) stop_all; rm -f "$ctl"; echo "rig stopped"; exit 0 ;;
      *) echo "ignored: $cmd"; continue ;;
    esac
    echo "$(date +%T) $cmd"
  done < "$ctl"
done
