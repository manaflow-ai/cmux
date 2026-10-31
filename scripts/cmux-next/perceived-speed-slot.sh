#!/bin/bash
# perceived-speed-slot.sh --job CMUX_CI_JOB --out DIR [--runs N] [--surface NAME ...]
#
# Runs perceived-speed.py against one DEV build (a finished `cmux-ci build cmux` job: debug.window_record
# is DEBUG only) in a capture slot: takes a slot lease, fetches the job's app onto the slot host, launches
# it, records every surface there, copies the recordings to DIR, quits the app, releases the slot, then
# analyzes here and prints the ranking table (DIR/table.md). Run from a fleet host; never on a personal machine.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# capture-host and the ssh routes to the capture minis (capture-host-env.sh).
. "$here/capture-host-env.sh"
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
lease="" host="" sock="" pid="" acquire="" state="" remote=/Users/Shared/cmux-capture/pspeed-out/$job-$$
release_slot() {
  # Quit through the app's own quit path (it also ends its terminal daemon), wait for its exact pid.
  if [ -n "$sock" ]; then
    ssh "$host" "python3 -c 'import json,socket,sys; c=socket.socket(socket.AF_UNIX); c.settimeout(5); c.connect(sys.argv[1]); c.sendall(json.dumps({\"id\":1,\"method\":\"action.run\",\"params\":{\"id\":\"quitEndSessions\"}}).encode()+b\"\\n\"); c.recv(65536)' '$sock'" >/dev/null 2>&1
    [ -n "$pid" ] && ssh "$host" "for _ in \$(seq 1 30); do kill -0 $pid 2>/dev/null || exit 0; sleep 1; done; echo 'perceived-speed: app pid $pid still up after quit' >&2"
    sock=""
  fi
  # Stop an acquire in flight (it ends the reservation of a lease it has not granted), then release a lease it
  # printed that this script had not read yet: a stop between the print and the read held the mini.
  if [ -n "$acquire" ]; then
    kill "$acquire" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$acquire" 2>/dev/null || break; sleep 0.2; done
    [ -n "$lease" ] || lease=$(grep '^slot-' "$work/lease" 2>/dev/null | tail -1)
  fi
  acquire=""
  [ -n "$lease" ] && capture-host release "$lease" >/dev/null 2>&1
  lease=""
  [ -n "$state" ] && ssh "$host" "rm -rf $state"
}
cleanup() {
  release_slot
  # The recordings and the staged app live outside the lease root: remove both.
  # PSPEED_KEEP_APP=1 keeps the staged app for another run of the same job.
  [ -n "$host" ] && ssh "$host" "rm -rf '$remote' '$cache.part'; [ -n '${PSPEED_KEEP_APP:-}' ] || rm -rf '$cache'"
  rm -rf "$work"
}
trap cleanup EXIT

# The app is staged once per job outside any lease (a fetch can outlive a 600 s lease). It is
# fetched ON the slot host with that host's cmux-ci (never relayed through this machine). When the
# lease lands on a host without it: release, stage there, lease again. Pin a host that paints
# (others' dialogs cover some minis) with CAPTURE_HOST_SLOT_HOSTS.
cache=/Users/Shared/cmux-capture/pspeed-apps/$job
stage() {
  ssh "$1" "export PATH=\$HOME/.local/bin:\$PATH; rm -rf $cache.part && mkdir -p $cache.part && cmux-ci artifact '$job' $cache.part/app.zip >/dev/null \
    && cd $cache.part && ditto -x -k app.zip . && rm app.zip && rm -rf $cache && mv $cache.part $cache"
}
# Room for the exclusive drain: acquire's deadline bounds it (120 s by default; a step on the mini may run 5).
export CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS="${CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS:-600}"
prefer=()
for attempt in 1 2 3; do
  # The lease lives as long as the acquire process; keep it in its own session.
  # Exclusive: no fleet step and no other capture on the mini while it records (its timings are
  # evidence only then; 2026-10-29 a run beside other agents' steps saw a 1-minute load of 14-24).
  # After staging, ask for the host the app was staged on first (acquire moves one host on per call).
  setsid capture-host acquire --slot --exclusive ${prefer[@]+"${prefer[@]}"} >"$work/lease" 2>&1 </dev/null &
  acquire=$!
  # Until acquire prints a lease or exits: it bounds itself, an exclusive drain included.
  while ! grep -q '^slot-' "$work/lease" && kill -0 "$acquire" 2>/dev/null; do sleep 2; done
  lease=$(grep '^slot-' "$work/lease" | tail -1)
  [ -n "$lease" ] || { echo "no capture slot: $(tail -3 "$work/lease")" >&2; exit 3; }
  eval "$(capture-host slot-info "$lease" | grep -E '^(host|slot|root)=')"
  echo "perceived-speed: lease $lease on $host slot $slot"
  ssh "$host" "ls -d $cache/*.app" >/dev/null 2>&1 && break
  capture-host release "$lease" >/dev/null 2>&1; lease=""; kill "$acquire" 2>/dev/null; acquire=""
  echo "perceived-speed: staging job $job on $host"
  stage "$host" || { echo "could not stage the app on $host" >&2; exit 3; }
  prefer+=(--prefer "$host")
done
[ -n "$lease" ] || { echo "no lease on a host with the app staged" >&2; exit 3; }
app=$(ssh "$host" "ls -d $cache/*.app | head -1")
# The build tag is baked into the app name (`cmux DEV <build tag>.app`). State persists per build tag
# and slot outside the lease root; start (and end) on a clean profile so runs never inherit workspaces.
btag=$(basename "$app" .app); btag=${btag#cmux DEV }
# The bundle id spells the tag's hyphens as dots (`whatsnew-ff` is `debug.whatsnew.ff`).
as="/Users/cmux/Library/Application Support" bid=com.cmuxterm.app.debug.${btag//-/.}.capslot$slot
state="'$as/cmux/$btag-capslot$slot' '$as/cmux/tags/$btag-capslot$slot' '$as/cmux/$bid' '$as/cmux/managed-status.$bid.json' '$as/cmux-next/$bid' '/Users/cmux/Library/Caches/$bid' '/Users/cmux/.acpmux/tags/$btag-capslot$slot'"
# Since per-build isolation a slot clone keeps its state under its build key, `<bundle id>--<tag slug>`
# (scripts/cmux-next/build_names.py): without these a run restores the last run's workspaces and tabs.
key="$bid--$(printf %s "$btag" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
state="$state '$as/cmux/builds/$key' '/Users/cmux/.acpmux/builds/$key'"
ssh "$host" "rm -rf $state"
# A slot app is never visible, so App Nap drops it to priority 4 after ~20 s; on a loaded host the
# main thread then waits seconds to be scheduled and every timing (and the DEBUG watchdog) reads
# the host, not cmux. Keep it awake.
capture-host launch "$lease" "$app" pspeed -- -NSAppSleepDisabled YES >"$work/launch" 2>&1
grep -q 'pid=' "$work/launch" || { echo "launch failed: $(tail -3 "$work/launch")" >&2; exit 3; }
cat "$work/launch"
pid=$(grep -o 'pid=[0-9]*' "$work/launch" | head -1 | cut -d= -f2)
# Recordings go outside the lease root, so the slot is released before the (slow) copy back.
ssh "$host" "rm -rf $remote && mkdir -p $remote"
scp -q "$here/perceived-speed.py" "$host:$remote/"
# The launcher's socket= path is never created. Older DEV builds listen on their BUILD tag's debug
# socket; newer ones at ~/.local/state/cmux/cmux-debug--<hash>.sock: match those by bundle id.
want=/tmp/cmux-debug-$btag-capslot$slot.sock
since=$(( $(ssh "$host" "date +%s") - 120 ))
found=""
for _ in $(seq 1 60); do
  ssh "$host" "[ -S '$want' ]" && { found=$want; break; }
  found=$(ssh "$host" "python3 $remote/perceived-speed.py find-socket '$bid' --since $since /tmp /Users/cmux/.local/state/cmux") && break
  found=""; sleep 1
done
[ -n "$found" ] || { echo "no app socket for $bid on $host: switch hosts (CAPTURE_HOST_SLOT_HOSTS)" >&2; exit 3; }
sock=$found
echo "perceived-speed: socket $sock"
sleep 4  # first window, prewarmed New Tab spare

ssh "$host" "cd $remote && PYTHONDONTWRITEBYTECODE=1 python3 perceived-speed.py run --socket '$sock' --out $remote/out --runs $runs ${surfaces[*]}"
status=$?
release_slot
ssh "$host" "cd $remote/out && tar cf - ." | tar xf - -C "$out" || status=3
for folder in "$out"/*/; do
  [ -f "$folder/meta.json" ] && [ -f "$folder/frames.json" ] || { echo "perceived-speed: $folder has no recording (the app quit or hung?)" >&2; continue; }
  python3 "$here/perceived-speed.py" analyze "$folder" --strip "$folder/strip.png" >"$folder/metrics.tmp" \
    && mv "$folder/metrics.tmp" "$folder/metrics.json" || { rm -f "$folder/metrics.tmp"; status=1; }
done
python3 "$here/perceived-speed.py" table "$out" | tee "$out/table.md"
exit $status
