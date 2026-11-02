#!/usr/bin/env bash
# round.sh SPEC_ID BUILD_JOB JOURNEY_ID [OUT_DIR]: one SWITCH FRAMES round, only through the mini scheduler.
# Waits for mini-queue/rounds/SPEC_ID.go, leases that host only (whole host: real HID keys need the key window),
# plays the journey with run.py from the pinned checkout this script lives in, writes SPEC_ID.done, then judges the
# movie on the VM (judge_switch.py) into OUT_DIR/<journey>/judge.json. Never cmux16; never a mini without a live GO.
set -u
spec=${1:?spec} build=${2:?build job} journey=${3:?journey id}
owner=${CMUX_AGENT_ID:-switch-frames}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
R=/work/wt/chrome-parity-design/mini-queue/rounds
out=${4:-/work/tmp/switch-frames/rounds/$spec-$(date -u +%m%dT%H%M%S)}
go=$R/$spec.go
mkdir -p "$(dirname "$out")"
log=$out.log
done_file() {  # status: pass | not run
  python3 -c 'import json,sys,time; json.dump({"spec":sys.argv[1],"owner":sys.argv[2],"at":time.time(),"go":sys.argv[3],"status":sys.argv[4]},open(sys.argv[5],"w"))' \
    "$spec" "$owner" "$go_at" "$1" "$R/$spec.done"
}
echo "round $spec build $build journey $journey out $out (waiting for $go)" >> "$log"
while :; do
  until [ -f "$go" ]; do sleep 5; done
  # Read the GO at once: the scheduler deletes the .go when the lease starts.
  read -r host go_at until_s < <(python3 -c 'import json,sys,datetime
g=json.load(open(sys.argv[1]))
u=datetime.datetime.fromisoformat(g["until"].replace("Z","+00:00")).timestamp()
print(g["host"], g["go"], int(u))' "$go") || { sleep 5; continue; }
  if [ "$(date +%s)" -ge "$until_s" ]; then echo "stale GO for $host (until passed); waiting for a new one" >> "$log"; sleep 20; continue; fi
  break
done
case " cmux16 cmux17 cmux20 " in *" $host "*) echo "refused host $host" >> "$log"; done_file "not run"; exit 2 ;; esac
echo "GO $host at $(date -u +%H:%M:%SZ) (go $go_at)" >> "$log"
cd "$root" || exit 2
CMUX_AGENT_ID=$owner CAPTURE_HOST_OWNER=$owner CAPTURE_HOST_POOL=perf-lead CAPTURE_HOST_SLOT_HOSTS="$host" \
CAPTURE_HOST_HOSTS="$host" CAPTURE_HOST_EXCLUDE="cmux16" \
  timeout 1500 python3 scripts/journeys/run.py --build "$build" --journey "$journey" --whole-host --exclusive \
  --hosts "$host" --out "$out" >> "$log" 2>&1
rc=$?
echo "run.py exit $rc at $(date -u +%H:%M:%SZ)" >> "$log"
d=$out/$journey/video
status=pass; { [ -f "$d/switch.mov" ] && [ $rc -le 1 ]; } || status="not run"
done_file "$status"
if [ -f "$d/switch.mov" ]; then
  /work/tmp/switch-frames/venv/bin/python "$here/judge_switch.py" --video "$d/switch.mov" --frames "$d/switch.mov.frames.json" \
    --events "$d/switch.events.json" --out "$d/judge.json" >> "$log" 2>&1
  echo "judge exit $?" >> "$log"
  /work/tmp/switch-frames/venv/bin/python "$here/strip.py" --judge "$d/judge.json" --out "$d/strips" >> "$log" 2>&1
else
  echo "no movie in $d" >> "$log"
fi
