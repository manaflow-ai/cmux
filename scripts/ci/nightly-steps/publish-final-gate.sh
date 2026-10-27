#!/usr/bin/env bash
# nightly.yml publish-nightly: "Final publication gate".
# Moved out of the workflow verbatim to keep nightly.yml under GitHub's
# workflow file size limit; the step's env: still sets every input.
set -euo pipefail
refuse() {
  # Not silent: the error annotation shows on the run, and
  # report-nightly-failure opens or updates the failure issue.
  echo "::error title=Publication refused::$SOURCE build $NIGHTLY_BUILD ($BUILD_SHA): $1; nothing published"
  echo "- refused: $1" >> "$GITHUB_STEP_SUMMARY"
  { echo "refused=true"; echo "refusal_reason=${1//[$'\r\n']/ }"; } >> "$GITHUB_OUTPUT"
  exit 0
}
# A deliberate stop (an operator made linux or none the writer, or set
# the hold, while this run built): publish nothing, and open no
# failure issue, since the next Mac publication may never come.
stand_down() {
  echo "::notice title=Publication stood down::$SOURCE build $NIGHTLY_BUILD ($BUILD_SHA): $1; nothing published"
  echo "- stood down: $1" >> "$GITHUB_STEP_SUMMARY"
  echo "refused=true" >> "$GITHUB_OUTPUT"
  exit 0
}
# var NAME: the live value without whitespace, "<unset>" when the
# variable does not exist (404); fails with the error on anything else.
var() {
  local out
  if out="$(GH_TOKEN="$WRITER_TOKEN" gh api "repos/$GITHUB_REPOSITORY/actions/variables/$1" --jq .value 2>"$RUNNER_TEMP/var.err")"; then
    tr -d '[:space:]' <<<"$out"; return 0
  fi
  if grep -q "HTTP 404" "$RUNNER_TEMP/var.err"; then printf '<unset>'; return 0; fi
  tr '\n' ' ' < "$RUNNER_TEMP/var.err"; return 1
}
if [ "$TRACK" = nightly-next ]; then
  [ -n "$WRITER_TOKEN" ] || refuse "the release App token could not be minted, so NIGHTLY_NEXT_WRITER is unreadable"
  writer="$(var NIGHTLY_NEXT_WRITER)" || refuse "NIGHTLY_NEXT_WRITER read live is unreadable: $writer"
  case "$writer" in
    mac) ;;
    linux|none) stand_down "NIGHTLY_NEXT_WRITER read live is '$writer', not mac" ;;
    *) refuse "NIGHTLY_NEXT_WRITER read live is '${writer:-<empty>}', not mac" ;;
  esac
  # Transition week only (until 2026-10-23): remove with NIGHTLY_NEXT_HOLD.
  hold="$(var NIGHTLY_NEXT_HOLD)" || refuse "NIGHTLY_NEXT_HOLD read live is unreadable: $hold"
  [ "$hold" != 1 ] || stand_down "NIGHTLY_NEXT_HOLD read live is 1"
  echo "NIGHTLY_NEXT_WRITER read live: mac (NIGHTLY_NEXT_HOLD: $hold); this pipeline publishes nightly-next"
fi
if [ "$SOURCE" = recovered ]; then
  status=0
  verdict="$(bash "$PUBLISH_TOOLING/ci/nightly-next-recovery-lineage.sh" "$GITHUB_REPOSITORY" "$CHANNEL_RELEASE_TAG" "$BUILD_SHA" </dev/null)" || status=$?
  if [ "$status" = 3 ]; then
    echo "::error title=Publication refused::recovered build $NIGHTLY_BUILD ($BUILD_SHA): $verdict"
    { echo "refused=true"; echo "refusal_reason=recovered build ${verdict//[$'\r\n']/ }"; } >> "$GITHUB_OUTPUT"
    exit 0
  elif [ "$status" != 0 ]; then
    # The check could not run: publish nothing, and say so in red.
    echo "::error title=Recovered build not checked::recovered build $NIGHTLY_BUILD ($BUILD_SHA): $verdict; nothing published"
    exit 1
  fi
  echo "$verdict"
fi
