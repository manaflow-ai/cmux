#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Generate third-party notices (cmux-next)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
#   app-third-party-notices.sh             take the hand-off in $RUNNER_TEMP/nightly-inputs/notices, else generate here;
#                                          then bundle the notices into the built app
#   app-third-party-notices.sh start       nightly-next-one: generate them in the background (background_build.py,
#                                          "notices") into that hand-off; they read no build output
#   app-third-party-notices.sh generate D  the background command: generate outside the checkout, then pack into D
#
# The background run never writes the checkout's THIRD_PARTY_LICENSES.md: the Release build copies the committed file,
# and bundle-notices replaces exactly that copy. A background run that fails packs nothing, so the plain step generates.
set -euo pipefail
handoff="$RUNNER_TEMP/nightly-inputs/notices"
generate() {
  # A trusted NEXT worker keeps the crate sources between jobs
  # (nightly_build_state.py); every other runner downloads them.
  export CMUX_NOTICES_CACHE="${CMUX_NEXT_NOTICES_CACHE:-$RUNNER_TEMP/cmux-notices}"
  ./scripts/cmux-next/generate-third-party-notices.sh --tui-source tree \
    --cargo-trees "$RUNNER_TEMP/cmux-notices-cargo-trees" --write-cargo-trees
}
case "${1:-}" in
  start)
    exec python3 scripts/ci/background_build.py start --state "$RUNNER_TEMP/nightly-helper-builds" notices -- \
      bash scripts/ci/nightly-steps/app-third-party-notices.sh generate "$handoff"
    ;;
  generate)
    out="${2:?generate needs the hand-off directory}"
    work="$RUNNER_TEMP/notices-background"
    rm -rf "$work" && mkdir -p "$work"
    CMUX_NOTICES_OUT="$work/THIRD_PARTY_LICENSES.md" generate
    python3 scripts/ci/nightly_inputs.py pack-notices "$out" --notices "$work/THIRD_PARTY_LICENSES.md"
    exit 0
    ;;
  "") ;;
  *) echo "usage: app-third-party-notices.sh [start | generate DIR]" >&2; exit 2 ;;
esac
if python3 scripts/ci/nightly_inputs.py install-notices "$handoff"; then
  status=0
else
  status=$?
fi
if [ "$status" != 0 ]; then
  [ "$status" = 3 ] || echo "::warning title=Notices hand-off::taking the handed-off notices failed (status $status); generating them here"
  generate
fi
python3 scripts/ci/nightly_inputs.py bundle-notices build-universal/Build/Products/Release/cmux.app
