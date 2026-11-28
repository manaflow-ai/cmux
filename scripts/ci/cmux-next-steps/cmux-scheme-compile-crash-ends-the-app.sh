#!/usr/bin/env bash
# cmux-next.yml cmux-scheme-compile: "Crash ends the app".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
built="$(find "$CMUX_NEXT_DERIVED_DATA/Build/Products/Debug" -maxdepth 1 -type d -name 'cmux DEV*.app' -print -quit)"
[[ -d "$built" ]] || { echo "::error::crash gate: no cmux DEV app in $CMUX_NEXT_DERIVED_DATA (not a crash freeze)"; exit 1; }
tag="ci-crash-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
app="$RUNNER_TEMP/crash-gate/cmux DEV ${tag}.app"
mkdir -p "$RUNNER_TEMP/crash-gate/out"
/bin/cp -R "$built" "$app"
trap 'python3 scripts/cmux-next/tag_teardown.py "$app" || true; rm -rf "$HOME/Library/Application Support/cmux-next/tags/$tag" "$HOME/Library/Application Support/cmux/tags/$tag" "$HOME/Library/Application Support/cmux-next/com.cmuxterm.app.debug.${tag//-/.}" "$HOME/Library/Caches/SentryCrash/cmux DEV $tag" "$HOME/.acpmux/builds/com.cmuxterm.app.debug--$tag" "$HOME/.cmux/mux/tags/$tag" "$app"' EXIT
python3 scripts/cmux-next/crash-ends-app-gate.py --app "$app" --out "$RUNNER_TEMP/crash-gate/out"
