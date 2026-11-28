#!/usr/bin/env bash
# One resume-matrix shard (.github/workflows/cloud-resume-matrix.yml machine and machine-day jobs): PARALLEL journeys
# side by side on this runner, each its own staging machine, each N samples per arm at PAUSE seconds, FILL% of the
# guest's memory resident, ARMS (empty: every arm), all ending by BUDGET_MIN from now. Each writes its own
# $RUNNER_TEMP/resume-matrix/PAUSE-SHARD[-K]/resume-matrix.json; the step fails if any journey did.
set -euo pipefail
: "${PAUSE:?}" "${N:?}" "${BUDGET_MIN:?}" "${SHARD:?}"
FILL="${FILL:-0}" ARMS="${ARMS:-}" PARALLEL="${PARALLEL:-1}"
cmux_tui="$RUNNER_TEMP/cmux-tui-bin/cmux-tui"
chmod +x "$cmux_tui"
# The journey's create and chat come first; the matrix ends by the budget from this step's start.
deadline=$(( $(date +%s) + BUDGET_MIN * 60 ))
arms=()
if [ -n "$ARMS" ]; then arms=(--resume-arms "$ARMS"); fi
pids=()
for k in $(seq 0 $(( PARALLEL - 1 ))); do
  out="$RUNNER_TEMP/resume-matrix/$PAUSE-$SHARD"
  if [ "$PARALLEL" -gt 1 ]; then out="$out-$k"; fi
  mkdir -p "$out"
  # A few seconds apart: each journey's tag is its start in ms, and creates side by side need not land at once.
  [ "$k" -eq 0 ] || sleep 3
  bun scripts/cmux-next/cloud-journey.ts --backend staging --out "$out" --cmux "$cmux_tui" \
    --model stub --resume-matrix "$PAUSE" --resume-n "$N" --resume-deadline "$deadline" --resume-fill "$FILL" "${arms[@]}" \
    > >(sed -u "s/^/[$k] /") 2>&1 &
  pids+=("$!")
done
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=$(( failed + 1 )); done
if [ "$failed" -gt 0 ]; then echo "::error::$failed of $PARALLEL journeys failed"; exit 1; fi
