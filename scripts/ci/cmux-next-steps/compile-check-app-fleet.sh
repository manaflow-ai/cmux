#!/usr/bin/env bash
# cmux-next.yml job `app-compile-fleet`, step "Compile-check the app at the pull request's head on the build fleet". Moved out of the workflow to keep it under
# GitHub's workflow file size limit (tests/test_ci_workflow_file_size.py); its env: stays in the workflow.
set -uo pipefail
# Why: note-478
no_verdict() {  # reason
  local fallback="No Mac Release compile runs for this change; re-run this job once the build fleet answers."
  [[ "${MAC_RELEASE:-}" == true ]] && fallback="The Mac Release compile (cmux-next Release compile (Xcode 26)) runs as the fallback; re-run this job once the build fleet answers."
  local summary="No build-fleet verdict for \`$REF\` ($1), so nothing has compiled this head here. $fallback"
  echo "verdict=unavailable" >> "$GITHUB_OUTPUT"
  echo "### Build fleet app compile: no verdict"$'\n\n'"$summary" >> "$GITHUB_STEP_SUMMARY"
  echo "::error title=Build fleet compile: no verdict::$summary"
  exit 1
}
# Why: 2026-11-24-app-compile-fleet-2.md
reader=scripts/ci/fleet_compile_result.py
if ! [[ -f "$reader" ]] || ! grep -q '"app-debug"' "$reader"; then
  no_verdict "the trusted compile result reader predates the app compile's own check"
fi
# Why: 2026-11-24-app-compile-fleet-3.md
word="$(python3 "$reader" --sha "$REF" --repo "$GITHUB_REPOSITORY" --pr "$PR" --phase app-debug --tier \
  --wait 2400 --no-record 300 2>"$RUNNER_TEMP/fleet-result.err")" || word=none
why=""
if [[ -f "$RUNNER_TEMP/fleet-result.err" ]]; then
  cat "$RUNNER_TEMP/fleet-result.err" >&2
  why="$(sed -n 's/^fleet compile result for [0-9a-f]*: [a-z]* (\(.*\))$/\1/p' "$RUNNER_TEMP/fleet-result.err" | tail -n 1)"
fi
how="Debug, swift.org toolchain"
case "$word" in
  pass) verdict=pass; summary="The build fleet compiled and linked the cmux-next app at \`$REF\` ($how). The Release compile runs at land." ;;
  fail) verdict=fail; summary="The cmux-next app did not compile on the build fleet at \`$REF\`: ${why:-no reason given}" ;;
  # Why: note-app-debug-tier
  awaiting_land) verdict=awaiting_land; summary="Deferred to land: ${why:-this pull request has no ready-to-land or full-ci label}. The build fleet compiles this head once the pull request is labeled, and the Release compile at land compiles it." ;;
  # Why: 2026-11-24-app-compile-fleet-4.md
  pending) verdict=unavailable; summary="The build fleet kept the compile of \`$REF\` queued past the wait, so nothing compiled this head here; the Release compile at land compiles it."
    echo "::warning title=Build fleet compile: still queued::no verdict for $REF; the Release compile at land compiles it" ;;
  *) no_verdict "the build fleet posted no result for this head (reader said ${word:-nothing})" ;;
esac
echo "verdict=$verdict" >> "$GITHUB_OUTPUT"
echo "### Build fleet app compile: $verdict"$'\n\n'"$summary" >> "$GITHUB_STEP_SUMMARY"
if [[ "$verdict" == fail ]]; then
  echo "::error title=Build fleet compile::$summary"
  exit 1
fi
