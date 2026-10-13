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
out=${1:-/tmp/restore-journey-$job-$(date +%H%M%S)}
[ $# -gt 0 ] && shift
[ "${1:-}" = "--" ] && shift
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
stage=/Users/Shared/cmux-capture/restore-journey/$job
run=$stage/run-$(date +%H%M%S)

capture-host acquire --slot >"$out/lease.txt" 2>"$out/lease.err" &
lease_pid=$!
release() {
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
  if ! find '$stage' -maxdepth 1 -name '*.app' | grep -q .; then cmux-ci artifact $job '$stage/app.zip' >/dev/null && cd '$stage' && ditto -x -k app.zip . && rm -f app.zip; fi"
scp -q "$here/restore-journey.py" "$here/../../cmux-tui/crates/acpmux/tests/fake_agent.py" "$host:$run/"
app=$(ssh -o BatchMode=yes "$host" "ls -d '$stage'/*.app | head -1")
name=$(basename "$app" .app)
build_tag=${name#cmux DEV }
capture-host launch "$lease" "$app" rj -- | tee "$out/launch.txt"
sock=/tmp/cmux-debug-$build_tag-capslot$slot.sock
for _ in $(seq 1 60); do ssh -o BatchMode=yes "$host" "test -S '$sock'" && break; sleep 1; done

set +e
ssh -o BatchMode=yes "$host" "cd '$run' && python3 restore-journey.py --socket '$sock' --out '$run/out' \
  --fake-agent '$run/fake_agent.py' --src '$app' $*" 2>&1 | tee "$out/journey.txt"
status=${PIPESTATUS[0]}
set -e
scp -q -r "$host:$run/out/." "$out/" || true
# Quit through the app's own action (sessions kept, as a person's quit); release stops the rest.
ssh -o BatchMode=yes "$host" "python3 -c 'import json,socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1]); s.sendall((json.dumps({\"id\":1,\"method\":\"action.run\",\"params\":{\"action\":\"quitKeepSessions\"}})+chr(10)).encode()); print(s.recv(4096)[:200])' '$sock'" || true
ssh -o BatchMode=yes "$host" "rm -rf '$run'" || true
echo "results in $out (exit $status)"
exit "$status"
