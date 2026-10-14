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

# The app is staged once per job outside any lease (a slow upload outlives a 600 s lease). Slot
# hosts have no cmux-ci on a non-login PATH, so it is fetched here and copied over. When the lease
# lands on a host without it: release, stage there, lease again.
cache=/Users/Shared/cmux-capture/pspeed-apps/$job
stage() {
  [ -f "$work/app.zip" ] || cmux-ci artifact "$job" "$work/app.zip" >/dev/null || { echo "could not fetch job $job" >&2; return 1; }
  ssh "$1" "rm -rf $cache.part && mkdir -p $cache.part" && scp -q "$work/app.zip" "$1:$cache.part/app.zip" \
    && ssh "$1" "cd $cache.part && ditto -x -k app.zip . && rm app.zip && rm -rf $cache && mv $cache.part $cache"
}
for attempt in 1 2 3; do
  # The lease lives as long as the acquire process; keep it in its own session.
  setsid capture-host acquire --slot >"$work/lease" 2>&1 </dev/null &
  for _ in $(seq 1 300); do grep -q '^slot-' "$work/lease" && break; sleep 2; done
  lease=$(grep '^slot-' "$work/lease" | tail -1)
  [ -n "$lease" ] || { echo "no capture slot: $(tail -3 "$work/lease")" >&2; exit 3; }
  eval "$(capture-host slot-info "$lease" | grep -E '^(host|slot|root)=')"
  echo "perceived-speed: lease $lease on $host slot $slot"
  ssh "$host" "ls -d $cache/*.app >/dev/null 2>&1" && break
  capture-host release "$lease" >/dev/null 2>&1; lease=""
  echo "perceived-speed: staging job $job on $host"
  stage "$host" || { echo "could not stage the app on $host" >&2; exit 3; }
done
[ -n "$lease" ] || { echo "no lease on a host with the app staged" >&2; exit 3; }
app=$(ssh "$host" "ls -d $cache/*.app | head -1")
capture-host launch "$lease" "$app" pspeed >"$work/launch" 2>&1
sock=$(grep -o 'socket=[^ ]*' "$work/launch" | tail -1 | cut -d= -f2)
[ -n "$sock" ] || { echo "launch failed: $(tail -3 "$work/launch")" >&2; exit 3; }
cat "$work/launch"
# The launcher names the slot's socket; a DEV build may answer on its tagged debug socket instead.
for _ in $(seq 1 60); do
  found=$(ssh "$host" "for s in '$sock' /tmp/cmux-debug-pspeed-capslot$slot.sock $root/tmp/cmux-debug-pspeed*.sock; do [ -S \"\$s\" ] && echo \"\$s\" && break; done")
  [ -n "$found" ] && break; sleep 1
done
[ -n "$found" ] || { echo "no app socket on $host (launcher said $sock): $(ssh "$host" "ls -la /tmp/*.sock $root/tmp 2>/dev/null | tail -8")" >&2; exit 3; }
sock=$found
echo "perceived-speed: socket $sock"
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
