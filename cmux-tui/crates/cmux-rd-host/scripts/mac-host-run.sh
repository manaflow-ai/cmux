#!/bin/zsh
# Starts the macOS host and the marker app on a test Mac, for the bench and the viewer pane.
# Run it from a process that holds Screen Recording and Accessibility (for example a
# terminal inside an app that has both), because the host inherits them.
#   mac-host-run.sh BIN_DIR STATE_DIR [--motion] [host flags...]   (--max-width reaches the marker too)
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
# STATE/host-flags (optional, one line) adds host flags, from this allowlist only:
# --max-width N, --max-fps N, --profile high|baseline, and --loopback 1 (serve 127.0.0.1 only,
# the host's default, for a viewer on this Mac such as the cmux-next pane).
reach=(--single-tenant-overlay 1)
bind=$(ifconfig | awk '/inet 100\./{print $2; exit}')
if [[ -f "$state/host-flags" ]]; then
  extra=(${=$(<"$state/host-flags")})
  for ((i = 1; i <= ${#extra}; i += 2)); do
    case "${extra[i]}=${extra[i+1]:-}" in
      --max-width=<->|--max-fps=<->|--profile=high|--profile=baseline) set -- "$@" "${extra[i]}" "${extra[i+1]}" ;;
      --loopback=1) reach=() bind=127.0.0.1 ;;
      *) echo "host-flags: refused ${extra[i]} ${extra[i+1]:-}" >&2; exit 2 ;;
    esac
  done
fi
# The marker sizes its cells in streamed pixels, so it needs the host's --max-width.
marker=(--verbose "${motion[@]}")
for ((i = 1; i < $#; i++)); do
  [[ ${@[i]} == --max-width ]] && marker+=(--stream-width "${@[i+1]}")
done
"$bin/cmux-rd-marker" "${marker[@]}" > "$state/marker.log" 2>&1 &
echo $! > "$state/marker.pid"
[[ -n $bind ]] || reach=()
"$bin/cmux-rd" host --owner owner "${reach[@]}" --bind "${bind:-127.0.0.1}" \
  --port 4103 "$@" --token-fd 3 3< <(cat "$state/token") > "$state/host.log" 2>&1 &
echo $! > "$state/host.pid"
echo "host pid $(cat "$state/host.pid") on ${bind:-127.0.0.1}:4103, marker pid $(cat "$state/marker.pid")"
