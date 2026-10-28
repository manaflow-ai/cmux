#!/bin/zsh
# Starts the macOS host and the marker app on a test Mac, for the bench and the viewer pane.
# Run it from a process that holds Screen Recording and Accessibility (for example a
# terminal inside an app that has both), because the host inherits them.
#   mac-host-run.sh BIN_DIR STATE_DIR [--motion] [host flags...]
# BIN_DIR holds cmux-rd and cmux-rd-marker. STATE_DIR gets token (0600), host.log and the
# pids. The host listens on the private overlay (--single-tenant-overlay 1) at port 4103.
set -u
bin=$1 state=$2
shift 2
motion=()
if [[ ${1:-} == --motion ]]; then motion=(--motion); shift; fi
mkdir -p "$state" && chmod 700 "$state"
for f in "$state"/*.pid(N); do kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; done
umask 077
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$state/token"
"$bin/cmux-rd-marker" "${motion[@]}" > "$state/marker.log" 2>&1 &
echo $! > "$state/marker.pid"
bind=$(ifconfig | awk '/inet 100\./{print $2; exit}')
"$bin/cmux-rd" host --owner owner --single-tenant-overlay 1 --bind "${bind:-127.0.0.1}" \
  --port 4103 "$@" --token-fd 3 3< <(cat "$state/token") > "$state/host.log" 2>&1 &
echo $! > "$state/host.pid"
echo "host pid $(cat "$state/host.pid") on ${bind:-127.0.0.1}:4103, marker pid $(cat "$state/marker.pid")"
