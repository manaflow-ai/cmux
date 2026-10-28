#!/usr/bin/env bash
# Run scripts/cmux-next/bench-restore.py on a fleet capture slot against a fleet build of cmux NEXT.
#
#   scripts/cmux-next/bench-restore-slot.sh JOB [OUT_DIR] [-- bench-restore args...]
#
# JOB is a done `cmux-ci build cmux` job (Debug, or --release of a chrome-parity-* tag: the bench
# configuration with the debug socket). The build is staged once per host under
# /Users/Shared/cmux-capture/bench-restore/<JOB>, launched in the slot with `capture-host launch`,
# and the bench runs on the host against the slot's socket. A lease lasts at most 10 minutes; the
# bench gets what is left less a margin, and the lease is released in every case (EXIT trap), which
# stops every process of the slot by exact PID. Results land in OUT_DIR (default
# /tmp/bench-restore-<JOB>-<time>): runs.jsonl, summary.json, bench.log.
# Pin a host with CAPTURE_HOST_SLOT_HOSTS. Never leases cmux16 (CAPTURE_HOST_EXCLUDE).
set -euo pipefail
job=${1:?usage: bench-restore-slot.sh JOB [OUT_DIR] [-- args]}
shift
[[ $job =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad JOB: $job" >&2; exit 2; }
out=/tmp/bench-restore-$job-$(date +%H%M%S)
if [ "${1:-}" = "--" ]; then
  shift
elif [ $# -gt 0 ]; then
  out=$1
  shift
  if [ "${1:-}" = "--" ]; then shift; fi
fi
args=$(printf '%q ' "$@")
here=$(cd "$(dirname "$0")" && pwd)
export CAPTURE_HOST_EXCLUDE="${CAPTURE_HOST_EXCLUDE:-cmux16}"
command -v capture-host >/dev/null || PATH="$HOME/.local/share/cmux/hq-tools/current/build-fleet:$PATH"
mkdir -p "$out"
stage=/Users/Shared/cmux-capture/bench-restore/$job
run=$stage/run-$(date +%H%M%S)-$$

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
[ -n "${lease:-}" ] || { echo "no capture slot" >&2; exit 75; }
info=$(capture-host slot-info "$lease")
host=$(sed -n 's/.*host=\([^ ]*\).*/\1/p' <<<"$info")
slot=$(sed -n 's/.*slot=\([^ ]*\).*/\1/p' <<<"$info")
echo "lease $lease host $host slot $slot" | tee "$out/host.txt"

ssh -o BatchMode=yes "$host" "export PATH=\$HOME/.local/bin:\$PATH; set -e; mkdir -p '$stage' '$run'
  if ! find '$stage' -maxdepth 1 -name '*.app' | grep -q .; then
    tmp=\$(mktemp -d '$stage/unzip.XXXXXX') && cmux-ci artifact '$job' \"\$tmp/app.zip\" >/dev/null && ditto -x -k \"\$tmp/app.zip\" \"\$tmp\" &&
    for a in \"\$tmp\"/*.app; do mv \"\$a\" '$stage/'; done; rm -rf \"\$tmp\"
  fi"
scp -q "$here/bench-restore.py" "$here/build_names.py" "$here/restore_slow_remote.py" "$host:$run/"
app=$(ssh -o BatchMode=yes "$host" "ls -d '$stage'/*.app | head -1")
capture-host launch "$lease" "$app" rr -- | tee "$out/launch.txt"
printed=$(grep -o 'socket=[^ ]*' "$out/launch.txt" | head -1 | cut -d= -f2- || true)
clone=$(sed -n 's/.* app=\(.*\.app\)$/\1/p' "$out/launch.txt" | head -1)
keyed=
if [ -n "$clone" ]; then
  keyed=$(ssh -o BatchMode=yes "$host" "python3 -I '$run/build_names.py' socket '$clone'" 2>/dev/null || true)
fi
name=$(basename "$app" .app)
build_tag=${name#cmux DEV }
sock=
for _ in $(seq 1 60); do
  for candidate in $keyed "/tmp/cmux-debug-$build_tag-capslot$slot.sock" $printed; do
    if ssh -o BatchMode=yes "$host" "python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1])' '$candidate'" 2>/dev/null; then
      sock=$candidate; break 2
    fi
  done
  sleep 1
done
[ -n "$sock" ] || { echo "the app never opened its control socket" >&2; exit 1; }
ssh -o BatchMode=yes "$host" "sw_vers -productVersion; sysctl -n hw.model; system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Resolution|Refresh' | head -4" >"$out/host-info.txt" 2>&1 || true

set +e
left=$((600 - ($(date +%s) - acquired) - 45))
[ "$left" -gt 90 ] || { echo "only ${left}s left on the lease; not starting the bench" >&2; exit 75; }
ssh -o BatchMode=yes "$host" "cd '$run' && python3 bench-restore.py --max-seconds $((left - 40)) --socket '$sock' --out '$run/out' $args" 2>&1 | tee "$out/bench.txt"
status=${PIPESTATUS[0]}
set -e
scp -q -r "$host:$run/out/." "$out/" || true
ssh -o BatchMode=yes "$host" "python3 -c 'import json,socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1]); s.sendall((json.dumps({\"id\":1,\"method\":\"action.run\",\"params\":{\"action\":\"quitKeepSessions\"}})+chr(10)).encode()); print(s.recv(4096)[:200])' '$sock'" >/dev/null 2>&1 || true
echo "results in $out (exit $status)"
exit "$status"
