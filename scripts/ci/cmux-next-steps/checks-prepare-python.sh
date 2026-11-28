#!/usr/bin/env bash
# cmux-next.yml checks: "Prepare check Python (PyYAML) and timeout".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
bin="$RUNNER_TEMP/checks-venv/bin"
python3 -m venv "$RUNNER_TEMP/checks-venv"
"$bin/python" -m pip install --disable-pip-version-check --no-input PyYAML==6.0.3 Pillow==11.3.0
# Why: docs/ci/cmux-next-workflow-notes.md#note-533
if ! command -v timeout >/dev/null; then
  if command -v gtimeout >/dev/null; then
    ln -s "$(command -v gtimeout)" "$bin/timeout"
  elif command -v perl >/dev/null; then
    # Why: docs/ci/cmux-next-workflow-notes.md#note-534
    printf '#!%s\nPATH="${PATH:+$PATH:}%s" exec %q %q "$@"\n' "$(command -v bash)" "$(dirname "$(command -v perl)")" \
      "$(command -v bash)" "$GITHUB_WORKSPACE/scripts/ci/timeout.sh" > "$bin/timeout"
    chmod +x "$bin/timeout"
  fi
fi
# Why: docs/ci/cmux-next-workflow-notes.md#note-503
command -v node >/dev/null || scripts/ci/ensure-setup-node.sh 24.22.1 \
  || echo "::warning title=checks preflight::ensure-setup-node.sh could not install node 24.22.1"
echo "$bin" >> "$GITHUB_PATH"
# Why: docs/ci/cmux-next-workflow-notes.md#note-504
PATH="$(awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) printf "%s:", line[i] }' "$GITHUB_PATH")$PATH"
missing=""
node --version >/dev/null 2>&1 || missing="$missing node,"
# The probe of the PATH timeout this step just provided (GNU, gtimeout or the timeout.sh shim), not a call of it.
command timeout 10 true >/dev/null 2>&1 || missing="$missing timeout (no GNU timeout, gtimeout or perl),"
python3 -c 'import yaml' >/dev/null 2>&1 || missing="$missing python3 with PyYAML,"
if [ -n "$missing" ]; then
  echo "::error title=checks preflight::${RUNNER_NAME:-this runner} lacks${missing%,}"
  exit 1
fi
