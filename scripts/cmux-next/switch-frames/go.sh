#!/usr/bin/env bash
# go.sh SPEC BUILD JOURNEY LABEL [VDISPLAY]: one SWITCH FRAMES / UI VIDEO round through the HARNESS kit (video-go.py:
# waits for the mini-scheduler GO, one whole-host lease, publishes the recording), then the switch judge and frame
# strips on the VM. VDISPLAY: 120x1 (default), 120x2 or none. SPEC_FILE=path: video-go hands that spec to the
# scheduler once the build is done (no GO before the build exists).
set -u
spec=${1:?spec} build=${2:?build} journey=${3:?journey} label=${4:?label} vd=${5:-120x1}
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../../.." && pwd)
out=/work/tmp/switch-frames/rounds/$spec-$(date -u +%m%dT%H%M%S)
log=$out.log; mkdir -p /work/tmp/switch-frames/rounds
cd "$root" || exit 2
export CMUX_AGENT_ID=${CMUX_AGENT_ID:-switch-frames}
echo "go.sh $spec $build $journey $label $vd out $out at $(date -u +%H:%M:%SZ)" >> "$log"
python3 scripts/journeys/video-go.py --spec "$spec" --build "$build" --journey "$journey" --label "$label" \
  --vdisplay "$vd" --out "$out" ${SPEC_FILE:+--spec-file "$SPEC_FILE"} >> "$log" 2>&1
echo "video-go exit $? at $(date -u +%H:%M:%SZ)" >> "$log"
d=$out/$journey/video
mov=$(ls "$d"/*.mov 2>/dev/null | head -1)
if [ -n "$mov" ] && [ -s "$mov" ]; then
  base=${mov%.mov}
  /work/tmp/switch-frames/venv/bin/python "$here/judge_switch.py" --video "$mov" --frames "$mov.frames.json" \
    --events "$base-keys.events.json" --out "$base.switch-judge.json" >> "$log" 2>&1
  echo "judge exit $?" >> "$log"
  /work/tmp/switch-frames/venv/bin/python "$here/strip.py" --judge "$base.switch-judge.json" --video "$mov" \
    --frames "$mov.frames.json" --out "$base.strips" >> "$log" 2>&1
else
  echo "no app movie (or an empty one) in $d" >> "$log"
fi
film=$(ls "$d"/*-display.mov 2>/dev/null | head -1)
if [ -n "$film" ] && [ -s "$film" ]; then
  base=${film%-display.mov}
  /work/tmp/switch-frames/venv/bin/python "$here/judge_switch.py" --video "$film" --clock beacon --hz 60 \
    --events "$base-keys.events.json" --out "$base-display.switch-judge.json" >> "$log" 2>&1
  echo "film judge exit $?" >> "$log"
  /work/tmp/switch-frames/venv/bin/python "$here/strip.py" --judge "$base-display.switch-judge.json" --video "$film" \
    --out "$base-display.strips" >> "$log" 2>&1
fi
