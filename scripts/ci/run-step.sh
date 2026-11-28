#!/usr/bin/env bash
# Any one step of ci/steps.toml on a build fleet machine, by name (Leo, 2026-11-19: "can't you... just be able to run
# whatever ci steps?"):
#
#   cmux-ci run --step NAME --ref SHA        (the client sends --script scripts/ci/run-step.sh --arg NAME)
#
# It runs `ci/run step NAME` in the step's checkout: the step as its job runs it (the job's setup, the tools the step
# needs, its timeout), with the step's own verdict (a non-blocking step that fails exits 1), 2 for a name the table at
# that commit lacks or a step whose job runs on the other OS (scripts/ci/ci_steps.py run_named_step).
#
# The step's command is the table's text, so the worker checks this script, ci/run, scripts/ci/ci_steps.py and
# ci/steps.toml against the reviewed branches (cmuxterm-hq build-fleet/cmd/worker/step_reviewed.go wrappedScripts):
# a branch's own edit of the table runs only once it lands.
set -euo pipefail

if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "run-step: usage: run-step.sh STEP (a ci/steps.toml step name: lowercase letters, digits and -)" >&2
  exit 2
fi
step="$1"
cd "$(dirname "$0")/../.."
exec python3 ci/run step "$step"
