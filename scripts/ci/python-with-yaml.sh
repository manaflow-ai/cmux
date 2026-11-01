#!/usr/bin/env bash
# Run a CI Python entry point with its workflow parser available. Keep any
# installation inside this job; never depend on or mutate the runner's Python.
set -euo pipefail
python=python3
if ! "$python" -c 'import yaml' >/dev/null 2>&1; then
  environment="${RUNNER_TEMP:?RUNNER_TEMP must name the job scratch directory}/cmux-yaml-venv"
  "$python" -m venv "$environment"
  python="$environment/bin/python"
  "$python" -m pip install --disable-pip-version-check --no-input PyYAML==6.0.3
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$environment/bin" >> "$GITHUB_PATH"
  fi
fi
exec "$python" "$@"
