#!/bin/bash
# perceived-speed-slot.sh --job CMUX_CI_JOB --out DIR [--runs N] [--surface NAME ...]
#
# Runs perceived-speed.py against one DEV build (a finished `cmux-ci build cmux` job: debug.window_record
# is DEBUG only) in a capture slot: takes a slot lease, fetches the job's app onto the slot host, launches
# it, records every surface there, copies the recordings to DIR, quits the app, releases the slot, then
# analyzes here and prints the ranking table (DIR/table.md). Run from big-red; never on Leo's machines.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
job="" out="" runs=3 surfaces=()
while [ $# -gt 0 ]; do
  case "$1" in
    --job) job=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --surface) surfaces+=(--surface "$2"); shift 2 ;;
    *) sed -n 2,7p "$0" >&2; exit 64 ;;
  esac
done
[ -n "$job" ] && [ -n "$out" ] || { sed -n 2,7p "$0" >&2; exit 64; }
mkdir -p "$out"
work=$(mktemp -d)
lease="" host="" sock=""
cleanup() {
  [ -n "$sock" ] && ssh "$host" "python3 -c 'import json,socket,sys; c=socket.socket(socket.AF_UNIX); c.settimeout(5); c.connect(sys.argv[1]); c.sendall(json.dumps({\"id\":1,\"method\":\"action.run\",\"params\":{\"id\":\"quit\"}}).encode()+b\"\\n\")' '$sock'" >/dev/null 2>&1
  [ -n "$lease" ] && capture-host release "$lease" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

# The lease lives as long as the acquire process; keep it in its own session.
setsid capture-host acquire --slot >"$work/lease" 2>&1 </dev/null &
for _ in $(seq 1 300); do grep -q '^slot-' "$work/lease" && break; sleep 2; done
lease=$(grep '^slot-' "$work/lease" | tail -1)
[ -n "$lease" ] || { echo "no capture slot: $(tail -3 "$work/lease")" >&2; exit 3; }
eval "$(capture-host slot-info "$lease" | grep -E '^(host|slot|root)=')"
echo "perceived-speed: lease $lease on $host slot $slot"

ssh "$host" "set -e; rm -rf $root/pspeed-app && mkdir -p $root/pspeed-app && cd $root/pspeed-app && cmux-ci artifact $job app.zip >/dev/null && ditto -x -k app.zip . && rm app.zip" \
  || { echo "could not fetch job $job onto $host" >&2; exit 3; }
app=$(ssh "$host" "ls -d $root/pspeed-app/*.app | head -1")
capture-host launch "$lease" "$app" pspeed >"$work/launch" 2>&1
sock=$(grep -o 'socket=[^ ]*' "$work/launch" | tail -1 | cut -d= -f2)
[ -n "$sock" ] || { echo "launch failed: $(tail -3 "$work/launch")" >&2; exit 3; }
for _ in $(seq 1 60); do ssh "$host" "test -S '$sock'" && break; sleep 1; done
sleep 4  # first window, prewarmed New Tab spare

remote=$root/pspeed
ssh "$host" "rm -rf $remote && mkdir -p $remote"
scp -q "$here/perceived-speed.py" "$host:$remote/"
ssh "$host" "cd $remote && PYTHONDONTWRITEBYTECODE=1 python3 perceived-speed.py run --socket '$sock' --out $remote/out --runs $runs ${surfaces[*]}"
status=$?
scp -q -r "$host:$remote/out/." "$out/" || status=3
for folder in "$out"/*/; do
  [ -f "$folder/meta.json" ] || continue
  python3 "$here/perceived-speed.py" analyze "$folder" --strip "$folder/strip.png" >"$folder/metrics.json" || status=1
done
python3 "$here/perceived-speed.py" table "$out" | tee "$out/table.md"
exit $status
