#!/usr/bin/env bash
# cmux-next.yml fast-tier-fleet: "Read the build fleet's fast tier verdict".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -uo pipefail
reader=scripts/ci/fleet_fast_tier_result.py
verdict=unavailable
if [[ -f "$reader" ]] && grep -q 'phase=fast-tier\|PHASE = "fast-tier"' "$reader" && command -v python3 >/dev/null; then
  args=(--sha "$REF" --repo "$GITHUB_REPOSITORY" --wait 2700 --queue-wait 1200 --no-record 300)
  if [[ "$FFI_REPIN" == true ]]; then args+=(--ffi-repin); else args+=(--home-render "$HOME_RENDER_SUITES" --cmux-next "$CMUX_NEXT_SUITES"); fi
  verdict="$(python3 "$reader" "${args[@]}" | tail -n1)" || verdict=unavailable
else
  echo "fleet fast tier: no reader at $REF"
fi
case "$verdict" in pass|fail|queued|unavailable) ;; *) verdict=unavailable ;; esac
echo "verdict=$verdict" >> "$GITHUB_OUTPUT"
echo "### cmux-next fast tier on the build fleet: $verdict" >> "$GITHUB_STEP_SUMMARY"
case "$verdict" in
  pass) exit 0 ;;
  queued) echo "::warning title=Fast tier on the build fleet: still queued::no verdict yet for $REF, so cmux-next fast tier runs the Swift suites itself"; exit 0 ;;
  fail) echo "::error title=Fast tier on the build fleet::a suite failed at $REF; the step lines above name it"; exit 1 ;;
  *) echo "::warning title=Fast tier on the build fleet: no verdict::the results service gave none for $REF; the Mac fallback reads it, else cmux-next fast tier runs the suites itself"; exit 0 ;;
esac
