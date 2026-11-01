#!/usr/bin/env bash
# nightly.yml build-nightly-inputs: the web bundles and third-party notices, moved out of the workflow to keep nightly.yml
# under GitHub's workflow file size limit.
#   key                  clear a reused workspace's web-bundles-out, write key=<source key> to $GITHUB_OUTPUT
#   build KEY RESTORED   install the restored source-key bundles (an incomplete restore builds them),
#                        then pack the hand-off for build-nightly-app
#   notices              generate the third-party notices and pack their hand-off
set -euo pipefail
case "${1:-}" in
  key)
    scripts/ci/clear-dirs.sh web-bundles-out
    echo "key=$(python3 scripts/cmux-next/web-bundle-key.py . --source)" >> "$GITHUB_OUTPUT"
    ;;
  build)
    key="$2" restored="$3"
    if [ "$restored" != true ] || ! scripts/cmux-next/build-web-bundles.sh --from web-bundles-out; then
      scripts/cmux-next/build-web-bundles.sh --force
    fi
    python3 scripts/ci/nightly_inputs.py pack-web "$RUNNER_TEMP/nightly-inputs/web" --source-key "$key"
    ;;
  notices)
    ./scripts/cmux-next/generate-third-party-notices.sh --tui-source tree \
      --cargo-trees "$RUNNER_TEMP/cmux-notices-cargo-trees" --write-cargo-trees
    python3 scripts/ci/nightly_inputs.py pack-notices "$RUNNER_TEMP/nightly-inputs/notices"
    ;;
  *) echo "usage: $0 key | build KEY RESTORED | notices" >&2; exit 2 ;;
esac
