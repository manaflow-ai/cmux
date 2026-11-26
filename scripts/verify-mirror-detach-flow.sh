#!/bin/bash
# End-to-end check of what a cmux mirror does to a shared tmux server, and what it leaves
# behind when the app quits.
#
# The three things this is here to catch, all seen for real on a live host:
#   1. A mirror claims a size for EVERY window, and tmux applies the smallest such claim as a
#      hard ceiling, so a narrow mirror letterboxes every other client's windows.
#   2. A mirror that goes away without saying `detach-client` leaves the remote half holding a
#      tmux client forever — over EternalTerminal the remote side outlives the local process —
#      and that dead client keeps its ceiling.
#   3. Quitting the app must not disturb clients it does not own.
#
# Usage: scripts/verify-mirror-detach-flow.sh <host> [--tag TAG]
# Exit 0 when every check passes.
set -uo pipefail

HOST="${1:?usage: verify-mirror-detach-flow.sh <host> [--tag TAG] [--broker NAME]}"
shift || true
TAG="fleet"
# A broker declared under remoteTmux.brokers in cmux.json, when the host is reached through
# one. Empty means connect directly.
BROKER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --broker) BROKER="${2:?--broker needs a value}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$REPO/scripts/cmux-debug-cli.sh"

BUNDLE="com.cmuxterm.app.debug.$TAG"
export CMUX_TAG="$TAG"
MASTER="/tmp/cm-$HOST"

pass=0; fail=0
check() { # description expected actual
  if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
rtmux() { ssh -o ControlPath="$MASTER" -- "$HOST" "tmux $*" 2>/dev/null; }

# Read-only view of the server. Control clients are the mirrors; everything else is a person.
clients()      { rtmux "list-clients -F '#{client_name} #{client_control_mode}'"; }
control_count(){ clients | awk '$2==1' | wc -l | tr -d ' '; }
plain_names()  { clients | awk '$2==0 {print $1}' | sort; }
sizes()        { rtmux "list-windows -t main -F '@#{window_id} #{window_width}x#{window_height}'"; }

if ! ssh -o ControlPath="$MASTER" -O check "$HOST" >/dev/null 2>&1; then
  echo "no ssh master at $MASTER — open one first (this script stays read-only otherwise)" >&2
  exit 2
fi
if ! pgrep -f "cmux DEV $TAG.app/Contents/MacOS/cmux DEV" >/dev/null 2>&1; then
  echo "the '$TAG' app is not running; launch it first" >&2
  exit 2
fi

echo "=== baseline ==="
BASE_PLAIN="$(plain_names)"
BASE_PLAIN_N="$(printf '%s\n' "$BASE_PLAIN" | grep -c . || true)"
BASE_CTRL="$(control_count)"
sizes | sed 's/^/  /'
printf 'plain clients: %s, control clients: %s\n' "$BASE_PLAIN_N" "$BASE_CTRL"
check "no leftover mirror client before we start" "0" "$BASE_CTRL"

echo "=== attaching the mirror over et (expect one Touch ID prompt) ==="
# The attach needs a terminal: its interactive authentication prompts on one, and a pipe
# would leave it with nowhere to ask.
BROKER_ARGS=""
[ -n "$BROKER" ] && BROKER_ARGS="--broker $BROKER"
script -q /dev/null "$CLI" ssh-tmux --transport et $BROKER_ARGS "$HOST" 2>&1 | tail -2
# The first probe after an attach can land before tmux has registered the client, and an ssh
# hiccup reads as zero, so this waits for the edge rather than sampling once.
seen=0
for _ in $(seq 1 30); do
  n="$(control_count)"
  if [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null; then seen=1; break; fi
  sleep 1
done
check "the mirror is attached as a control client" "1" "$seen"

MIRROR_SIZE="$(rtmux "list-clients -F '#{client_control_mode} #{client_width}'" | awk '$1==1{print $2; exit}')"
echo "mirror claims width: ${MIRROR_SIZE:-unknown}"
echo "window sizes while the mirror is attached:"
sizes | sed 's/^/  /'

echo "=== quitting the app, the way the close button does ==="
osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1
for _ in $(seq 1 30); do
  pgrep -f "cmux DEV $TAG.app/Contents/MacOS/cmux DEV" >/dev/null 2>&1 || break
  sleep 1
done
check "the app exited" "0" "$(pgrep -f "cmux DEV $TAG.app/Contents/MacOS/cmux DEV" >/dev/null 2>&1 && echo 1 || echo 0)"

# The server needs a moment to notice the detach.
sleep 3
echo "=== after the quit ==="
sizes | sed 's/^/  /'
check "the mirror released its tmux client" "0" "$(control_count)"
check "clients we did not own are untouched" "$BASE_PLAIN" "$(plain_names)"

printf -- '---- %s passed, %s failed ----\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
