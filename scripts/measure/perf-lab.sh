#!/usr/bin/env bash
# Fleet entry of the perf lab (plans/cmux-next/chrome-parity/p12-perf-process.md): measures the prebuilt bench app of
# one commit on one lab host, never building it. Runs at the tip ref, so an old commit is measured with today's harness:
#   cmux-ci run --class exclusive --measurement --label perf-lab --script scripts/measure/perf-lab.sh --ref <tip> \
#     --arg=--sha=<sha> --arg=--digest=sha256:<hex> [--arg=--config=bench-checks] \
#     (--arg=--shard=K/N | --arg=--stories=a,b) [--arg=--repeats=N] --artifact artifacts/perf-lab.tgz
#   cmux-ci run ... --script scripts/measure/perf-lab.sh --ref <tip> --arg=--env-only    # validate the host only
# scripts/perf-lab/run_story.py does the work (its docstring has the steps and exit codes: 3 env-invalid, 4 no such
# artifact); the digest is the one scripts/measure/perf-lab-build.sh printed for (sha, config). Results:
# artifacts/perf-lab/results/*.ndjson (result-v1), rejected/, summary.json, host.json, logs/, packed on exit into the
# one uploaded file artifacts/perf-lab.tgz. The fetched app, its zip and the virtual display helper stay in
# artifacts/perf-lab-work/, which is never uploaded and is removed on exit.
#
# On exit, TERM, INT or HUP (a cancelled step) the trap stops the runner (which ends its story's process group and
# the virtual display), then ends the app's daemons (scripts/cmux-next/tag_teardown.py, exact PIDs of the bundle) and
# a virtual display helper the runner left.
#
# A changed blob (this script, or a new version of it) is registered like this. The controller accepts an unlisted
# scripts/measure/<name>.sh only at a commit on feat-cmux-next or main (cmuxterm-hq measure_reviewed.go), and the
# worker runs it only when its blob at the step's commit equals that path at the tip of feat-cmux-next or main
# (step_reviewed.go, build-fleet/ONBOARDING.md). So an edit here measures nothing until it lands on feat-cmux-next:
# 1. land the edit on feat-cmux-next (bump PERF_LAB_MEASURE_VERSION when what is measured or how changes);
# 2. run the lab at that tip (--ref <feat-cmux-next tip>); results name the measured --sha, not the ref;
# 3. to run it from perf/chrome-parity before it lands, add "scripts/measure/perf-lab.sh": true to measureScripts in
#    cmuxterm-hq build-fleet/cmd/controller/ci_step.go, with its case in measure_allowlist_test.go (an hq PR). The
#    worker's blob check still applies, so only a blob that equals the reviewed one runs.
set -euo pipefail
# The measurement's version: bump it in an edit that changes what is measured or how (a comment or log edit keeps it).
PERF_LAB_MEASURE_VERSION=1
cd "$(git rev-parse --show-toplevel)"
out="$(pwd)/artifacts/perf-lab"
work="$(pwd)/artifacts/perf-lab-work"
report="$(pwd)/artifacts/perf-lab.tgz"
rm -rf "$out" "$work" "$report"  # this step's results only: a reused checkout must not upload an earlier job's files
mkdir -p "$out" "$work"
state="$work/state.json"
runner_pid=""

# shellcheck disable=SC2317,SC2329 # run by the traps below
cleanup() {
  trap - EXIT TERM INT HUP
  if [[ -n "$runner_pid" ]] && kill -0 "$runner_pid" 2>/dev/null; then
    kill -TERM "$runner_pid" 2>/dev/null || true  # the runner this script started, by its PID
    wait "$runner_pid" 2>/dev/null || true
  fi
  if [[ -f "$state" ]]; then
    teardown_state
  fi
  # The one uploaded file: the results and their evidence, never the app or the helper in $work.
  tar -czf "$report" -C "$out" . 2>/dev/null || echo "perf-lab: could not pack $out" >&2
  rm -rf "$work"
}
# shellcheck disable=SC2317,SC2329 # run by cleanup
teardown_state() {
  local app vdisplay_pid
  app="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("app") or "")' "$state" 2>/dev/null || true)"
  vdisplay_pid="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("vdisplay_pid") or "")' "$state" 2>/dev/null || true)"
  if [[ -n "$app" ]]; then
    python3 -I scripts/cmux-next/tag_teardown.py "$app" || true
  fi
  # Only the helper the runner started: that pid, while it still runs our VDisplay.app.
  if [[ "$vdisplay_pid" =~ ^[0-9]+$ ]] && ps -o command= -p "$vdisplay_pid" 2>/dev/null | grep -q "$work/vdisplay/VDisplay.app"; then
    kill "$vdisplay_pid" 2>/dev/null || true
  fi
}
# shellcheck disable=SC2317,SC2329 # run by the traps below
on_signal() {
  echo "perf-lab: signal $1; ending the runner, the app and the virtual display" >&2
  cleanup
  exit $((128 + $2))
}
trap cleanup EXIT
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2' INT
trap 'on_signal HUP 1' HUP

status=0
# In the background and waited for, so a TERM reaches the trap at once (bash runs a trap only between commands).
python3 -I scripts/perf-lab/run_story.py --out "$out" --work "$work" --state "$state" \
  --measure-version "$PERF_LAB_MEASURE_VERSION" "$@" &
runner_pid=$!
wait "$runner_pid" || status=$?
runner_pid=""
exit "$status"
