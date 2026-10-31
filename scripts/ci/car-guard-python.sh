#!/usr/bin/env bash
# Prints a python3 that has the workflow-guard test modules, pinned as ci-guards.yml installs
# them (PyYAML 6.0.3, bashlex 0.18). The runner's python3 when it has them; else a venv made
# once per runner under ${RUNNER_TEMP:-/tmp} (flock, so parallel cars share one install).
# Used by the car guards: a focused test must not fail for a module the runner lacks.
set -euo pipefail
if [[ -n "${CAR_GUARD_PYTHON:-}" ]]; then
  echo "$CAR_GUARD_PYTHON"  # a caller that already has one (tests, a prepared runner)
  exit 0
fi
if python3 -c 'import yaml, bashlex' 2> /dev/null; then
  command -v python3
  exit 0
fi
venv="${RUNNER_TEMP:-/tmp}/car-guard-venv"
exec 9> "$venv.lock"
flock 9 2> /dev/null || true
if ! "$venv/bin/python" -c 'import yaml, bashlex' 2> /dev/null; then
  python3 -m venv "$venv" >&2
  "$venv/bin/python" -m pip install --disable-pip-version-check --no-input --quiet PyYAML==6.0.3 bashlex==0.18 >&2
fi
echo "$venv/bin/python"
