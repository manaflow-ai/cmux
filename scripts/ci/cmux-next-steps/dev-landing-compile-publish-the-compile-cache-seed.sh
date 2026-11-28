#!/usr/bin/env bash
# cmux-next.yml dev-landing-compile: "Publish the compile cache seed".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -uo pipefail
pack="$RUNNER_TEMP/cmux-next-dev-cas-pack"
[[ -f "$pack/pack.json" ]] || { echo "no compile cache seed packed (not a host build)"; exit 0; }
python3 -I scripts/cmux-next/dev_cas_seed.py publish --pack "$pack" --out "$RUNNER_TEMP/cmux-next-dev-cas-record" >> "$GITHUB_OUTPUT"
rm -rf -- "$pack"
