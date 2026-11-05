#!/usr/bin/env bash
# CMD-N LATENCY bench (cmux-ad m6 2c): Cmd-N key -> first frame of the new workspace, and a new terminal -> its first
# visible prompt, light and STRESS-lite, on ONE exact fleet build, from the app's own timing (debug.new_tab bench_create,
# debug.action_budget, debug.new_terminal_trace). Not a CI job, step or gate.
#
#   cmdn-latency.sh BUILD_JOB MINI [PRESSES] [AGENT_ID]
#     BUILD_JOB  a fleet cmux build job id whose app has the bench hooks (every FEAT DOGFOOD BUILD has them)
#     MINI       a perf mini: cmux18 cmux19 cmux21 cmux22 cmux23 cmux24 (never cmux16 or cmux20; cmux17 only after its handover)
#     PRESSES    counted presses per session (default 20; warm-up presses are extra)
#     AGENT_ID   the owner's 17-hex agent id (default: the CMD-N LATENCY owner a5f17d71c95f83bee)
# It asks the mini scheduler for ONE lease round on MINI (priority 6, below the P0 journey runner), waits for the GO,
# plays journey cmdn-latency there (whole host, exclusive), writes the round's .done, and prints the summary
# (cmdn_latency_summary.py). Output: /work/wt/cmdn-latency/runs/<job8>-<mini>-<UTC time>/.
set -u
BUILD=${1:?BUILD_JOB}; HOST=${2:?MINI}; PRESSES=${3:-20}; AGENT=${4:-a5f17d71c95f83bee}
# JOURNEY=cmdn-profile: the same presses with debug.hangs per press (main-thread stalls and their stacks).
J=${JOURNEY:-cmdn-latency}
# OWNER: the STATUS name of the round's owner (CMD-N FIRST FRAME runs its probes through this driver too).
OWNER=${OWNER:-CMD-N LATENCY}
case "$HOST" in cmux18|cmux19|cmux21|cmux22|cmux23|cmux24) ;; cmux17) grep -q "CMUX17 HANDED TO THE SCHEDULER" /Users/lawrence/fun/wt/handoff/cmux-lead-status-3.md || { echo "cmux17 is not handed over"; exit 2; } ;; *) echo "refused mini $HOST"; exit 2 ;; esac
KIT=$(cd "$(dirname "$0")/../.." && pwd)
Q=/work/wt/chrome-parity-design/mini-queue; R=$Q/rounds
STAMP=$(date -u +%H%M%S); S="cmdn-lat-${BUILD:0:8}-$HOST-$STAMP"
OUT=/work/wt/cmdn-latency/runs/${BUILD:0:8}-$HOST-$(date -u +%m%dT%H%M%S); mkdir -p "$OUT"
# A build that still runs is waited for (no lease is asked before it is done).
until st=$(~/.local/bin/cmux-ci status "$BUILD" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('state'))" 2>/dev/null); \
  [ "$st" = done ] || [ "$st" = failed ] || [ "$st" = cancelled ]; do sleep 60; done
[ "$st" = done ] || { echo "build $BUILD is $st, not done"; exit 3; }
cat > "$Q/specs/$S.json.tmp" <<SPEC
{"name": "$OWNER: journey $J on build $BUILD ($PRESSES presses per session)", "owner": "$OWNER agent $AGENT", "agent_id": "$AGENT", "kind": "lease-round", "recur": "once", "p0": false, "priority": 6, "order": 0, "minutes": 8, "hold_minutes": 10, "rounds": 1, "minis": ["$HOST"], "cmux_ci_args": [], "verdict": "/work/wt/chrome-parity-design/mini-queue/verdicts/swift-suite.py", "note": "whole host, exclusive; driver $KIT/scripts/journeys/cmdn-latency.sh: run.py --build $BUILD --journey $J"}
SPEC
mv "$Q/specs/$S.json.tmp" "$Q/specs/$S.json"
echo "queued round $S; waiting for its GO"
while [ ! -f "$R/$S.go" ]; do sleep 10; done
GO=$(cat "$R/$S.go")
UNTIL=$(python3 -c 'import json,sys,datetime; print(int(datetime.datetime.fromisoformat(json.loads(sys.argv[1])["until"].replace("Z","+00:00")).timestamp()))' "$GO")
BUDGET=$(( UNTIL - $(date +%s) - 20 )); [ $BUDGET -lt 60 ] && BUDGET=60; ACQ=$(( BUDGET / 2 ))
echo "GO on $HOST at $(date -u +%H:%M:%SZ); out $OUT"
EXCL=""; for h in cmux16 cmux17 cmux18 cmux19 cmux20 cmux21 cmux22 cmux23 cmux24; do [ "$h" != "$HOST" ] && EXCL="$EXCL $h"; done
(cd "$KIT" && env CMUX_AGENT_ID=$AGENT CAPTURE_HOST_POOL=perf-lead CAPTURE_HOST_HOSTS=$HOST CAPTURE_HOST_SLOT_HOSTS=$HOST JOURNEYS_EXCLUDE_HOSTS="${EXCL# }" \
  JOURNEYS_P0_LEDGER=$OUT/kit-ledger PYTHONUNBUFFERED=1 CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS=$ACQ \
  CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS=$(( BUDGET - ACQ )) CAPTURE_HOST_DRAIN_SECONDS=$(( ACQ < 180 ? ACQ : 180 )) \
  python3 scripts/journeys/run.py --build "$BUILD" --journey "$J" --journey-option presses="$PRESSES" \
    --exclusive --whole-host --hosts "$HOST" --frame-interval 60 --out "$OUT/run") > "$OUT/run.log" 2>&1
CODE=$?
# The round's status is the measurement's: pass when both sessions' Cmd-N runs were recorded (the journey's own
# end checks are kept in result.json but do not decide whether the numbers exist).
STATUS=$(python3 -c 'import json,sys
r=json.load(open(sys.argv[1])); labels={(s.get("result") or {}).get("label") for s in r.get("steps") or [] if s.get("do")=="latency_runs" and s.get("ok")}
print("pass" if {"light","stress"} <= labels else r.get("status","not run"))' "$OUT/run/$J/result.json" 2>/dev/null || echo "not run")
python3 -c 'import json,sys,datetime; json.dump({"at":datetime.datetime.now(datetime.timezone.utc).isoformat(),"go":json.loads(sys.argv[1]).get("go"),"status":sys.argv[2],"runner":"cmdn-latency"},open(sys.argv[3]+".tmp","w"))' "$GO" "$STATUS" "$R/$S.done"
mv "$R/$S.done.tmp" "$R/$S.done"
# One round only: the spec goes, so a "not run" never makes the scheduler hold the mini for a GO nobody takes.
sleep 30; rm -f "$Q/specs/$S.json"
echo "END exit $CODE status $STATUS out $OUT"
python3 "$KIT/scripts/journeys/cmdn_latency_summary.py" "$OUT/run" | tee "$OUT/summary.txt"
