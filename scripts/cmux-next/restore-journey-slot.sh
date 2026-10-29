#!/usr/bin/env bash
# Run scripts/cmux-next/restore-journey.py on a fleet capture slot against a fleet DEV build.
#
#   scripts/cmux-next/restore-journey-slot.sh JOB [OUT_DIR] [-- restore-journey args...]
#
# JOB is a done `cmux-ci build cmux` job. The build is staged once per host under
# /Users/Shared/cmux-capture/restore-journey/<JOB> (outside the lease root, so a re-acquire only
# relaunches), launched in the slot with `capture-host launch`, and the journey runs on the host
# against the slot's socket. The journey's own relaunches reuse the app's launch environment. At
# the end the app quits through its quit action (sessions kept) and the lease is released, which
# stops every process of the slot by exact PID. A lease lasts at most 10 minutes; the journey
# takes about 4. Results land in OUT_DIR (default /tmp/restore-journey-<JOB>-<time>).
# Pin a host with CAPTURE_HOST_SLOT_HOSTS (one with free disk; see `capture-host status`).
set -euo pipefail
job=${1:?usage: restore-journey-slot.sh JOB [OUT_DIR] [-- args]}
shift
[[ $job =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad JOB: $job" >&2; exit 2; }
out=/tmp/restore-journey-$job-$(date +%H%M%S)
if [ "${1:-}" = "--" ]; then
  shift
elif [ $# -gt 0 ]; then
  out=$1
  shift
  if [ "${1:-}" = "--" ]; then shift; fi
fi
# No args: nothing (printf '%q ' with no arguments prints '' and passed restore-journey.py an empty argument).
args=
[ $# -eq 0 ] || args=$(printf '%q ' "$@")
here=$(cd "$(dirname "$0")" && pwd)
# capture-host and the ssh routes to the capture minis (capture-host-env.sh).
. "$here/capture-host-env.sh"
mkdir -p "$out"
stage=/Users/Shared/cmux-capture/restore-journey/$job
run=$stage/run-$(date +%H%M%S)

acquired=$(date +%s)
capture-host acquire --slot >"$out/lease.txt" 2>"$out/lease.err" &
lease_pid=$!
release() {
  if [ -n "${host:-}" ]; then ssh -o BatchMode=yes "$host" "rm -rf '$run'" >/dev/null 2>&1 || true; fi
  if [ -n "${lease:-}" ]; then capture-host release "$lease" >/dev/null 2>&1 || true; fi
  kill "$lease_pid" 2>/dev/null || true
}
trap release EXIT
for _ in $(seq 1 120); do
  lease=$(grep -o 'slot-[A-Za-z0-9._-]*' "$out/lease.txt" 2>/dev/null | head -1 || true)
  [ -n "$lease" ] && capture-host slot-info "$lease" >/dev/null 2>&1 && break
  kill -0 "$lease_pid" 2>/dev/null || { cat "$out/lease.err" >&2; exit 1; }
  sleep 2
done
info=$(capture-host slot-info "$lease")
host=$(sed -n 's/.*host=\([^ ]*\).*/\1/p' <<<"$info")
slot=$(sed -n 's/.*slot=\([^ ]*\).*/\1/p' <<<"$info")
echo "lease $lease host $host slot $slot"

ssh -o BatchMode=yes "$host" "export PATH=\$HOME/.local/bin:\$PATH; set -e; mkdir -p '$stage' '$run'
  if ! find '$stage' -maxdepth 1 -name '*.app' | grep -q .; then
    tmp=\$(mktemp -d '$stage/unzip.XXXXXX') && cmux-ci artifact '$job' \"\$tmp/app.zip\" >/dev/null && ditto -x -k \"\$tmp/app.zip\" \"\$tmp\" &&
    for a in \"\$tmp\"/*.app; do mv \"\$a\" '$stage/'; done; rm -rf \"\$tmp\"
  fi"
scp -q "$here/restore-journey.py" "$here/build_names.py" "$here/rj_rows.py" "$here/rj_fake_cli_agent.py" "$here/../../cmux-tui/crates/acpmux/tests/fake_agent.py" "$host:$run/"
app=$(ssh -o BatchMode=yes "$host" "ls -d '$stage'/*.app | head -1")
name=$(basename "$app" .app)
build_tag=${name#cmux DEV }
capture-host launch "$lease" "$app" rj -- | tee "$out/launch.txt"
# The app's control socket: the build's own (build_names.py: a slot clone, whose bundle id does
# not end in its tag, gets cmux-debug--<key hash>.sock in ~/.local/state/cmux, then its /tmp
# link); before per-build isolation it was
# named from the build tag; capture-host also prints the one it set.
printed=$(grep -o 'socket=[^ ]*' "$out/launch.txt" | head -1 | cut -d= -f2- || true)
clone=$(sed -n 's/.* app=\(.*\.app\)$/\1/p' "$out/launch.txt" | head -1)
keyed=
if [ -n "$clone" ]; then
  keyed=$(ssh -o BatchMode=yes "$host" "python3 -I '$run/build_names.py' socket '$clone'" 2>/dev/null || true)
fi
sock=
for _ in $(seq 1 60); do
  for candidate in $keyed "/tmp/cmux-debug-$build_tag-capslot$slot.sock" $printed; do
    # A socket that accepts a connection (an earlier lease can leave a dead socket file behind).
    if ssh -o BatchMode=yes "$host" "python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])' '$candidate'" 2>/dev/null; then
      sock=$candidate; break 2
    fi
  done
  sleep 1
done
up=$sock
[ -n "$up" ] || { echo "the app never opened its control socket" >&2; exit 1; }

set +e
# Bounded by the lease (10 minutes from acquire, less a margin to quit): the journey must not outlive the slot.
left=$((600 - ($(date +%s) - acquired) - 40))
[ "$left" -gt 120 ] || { echo "only ${left}s left on the lease; not starting the journey" >&2; exit 1; }
ssh -o BatchMode=yes "$host" "cd '$run' && python3 restore-journey.py --max-seconds $left --socket '$sock' --out '$run/out' \
  --fake-agent '$run/fake_agent.py' --src '$app' $args" 2>&1 | tee "$out/journey.txt"
status=${PIPESTATUS[0]}
set -e
scp -q -r "$host:$run/out/." "$out/" || true
# Quit through the app's own action (sessions kept, as a person's quit); release stops the rest.
ssh -o BatchMode=yes "$host" "python3 -c 'import json,socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1]); s.sendall((json.dumps({\"id\":1,\"method\":\"action.run\",\"params\":{\"action\":\"quitKeepSessions\"}})+chr(10)).encode()); print(s.recv(4096)[:200])' '$sock'" || true
echo "results in $out (exit $status)"
exit "$status"
