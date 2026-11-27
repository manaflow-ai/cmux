#!/usr/bin/env bash
# cmux-next.yml job `swift-canary-fleet`, step "Compile-check CmuxNext on the build fleet". Moved out of the workflow to keep it under
# GitHub's workflow file size limit (tests/test_ci_workflow_file_size.py); its env: stays in the workflow.
set -uo pipefail
# Why: note-452
for target in $SWIFT_CANARY_TARGETS; do
  case "$target" in
    CmuxNextServerHelperDaemon|CmuxNextUiLayerPreview)
      echo "::notice title=Build fleet compile check::$target is not linked into the app; the Mac canary runs."
      echo "verdict=unavailable" >> "$GITHUB_OUTPUT"
      exit 0 ;;
  esac
done
# Why: 2026-11-24-swift-canary-fleet-2.md
if [[ -n "${PR:-}" ]]; then
  word=none
  reader=scripts/ci/fleet_compile_result.py
  if [[ -f "$reader" ]] && grep -q '"app-debug"' "$reader"; then
    word="$(python3 "$reader" --sha "$REF" --repo "$GITHUB_REPOSITORY" --pr "$PR" --phase app-debug \
      --wait 2400 --no-record 300)" || word=none
  fi
  case "$word" in
    pass) verdict=pass; echo "::notice title=Build fleet compile check::the build fleet compiled and linked this head (Debug); not compiled again" ;;
    fail) verdict=fail; echo "::notice title=Build fleet compile check::CmuxNext did not compile on the build fleet; the Mac canary runs and shows the errors." ;;
    *) verdict=unavailable; echo "::notice title=Build fleet compile check::No build-fleet verdict ($word); the Mac canary runs." ;;
  esac
  echo "verdict=$verdict" >> "$GITHUB_OUTPUT"
  exit 0
fi
# A push reads the tip check and falls back to the Mac canary when unavailable.
# Why: 2026-11-24-swift-canary-fleet-3.md
word=none
if [[ -f scripts/ci/fleet_compile_result.py ]] && command -v python3 >/dev/null; then
  word="$(python3 scripts/ci/fleet_compile_result.py --sha "$REF" --repo "$GITHUB_REPOSITORY" --wait 2400 --no-record 600)" || word=none
fi
# Why: note-551
if [[ "$word" == superseded ]]; then
  authorization="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  # A failed read says so in the log (origin-net.test.sh: no remote read swallows its failure) and compiles here.
  head=""
  if refs="$(bash scripts/ci/timeout.sh 60 git -c "http.extraHeader=Authorization: Basic $authorization" \
    -c http.lowSpeedLimit=1 -c http.lowSpeedTime=15 ls-remote "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git" "$GITHUB_REF")"; then
    head="$(awk 'NR==1{print $1}' <<<"$refs")"
  else
    echo "::warning title=Build fleet compile check::could not read the head of $GITHUB_REF (exit $?); not taking the superseded answer"
  fi
  if [[ -n "$head" && "$head" != "$REF" ]]; then
    echo "::notice title=Build fleet compile check::superseded push $REF: the branch head is $head, whose tip check covers this push; not compiled here"
    echo "verdict=superseded" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  word=none
fi
case "$word" in
  pass) verdict=pass; echo "::notice title=Build fleet compile check::the tip check compiled this head (SwiftPM Release -Onone); not compiled again" ;;
  fail) verdict=fail; echo "::notice title=Build fleet compile check::CmuxNext did not compile on the build fleet; the Mac canary runs and shows the errors." ;;
  *) verdict=unavailable; echo "::warning title=mac fallback::No build-fleet verdict for $REF ($word); the Mac Swift canary runs." ;;
esac
echo "verdict=$verdict" >> "$GITHUB_OUTPUT"
