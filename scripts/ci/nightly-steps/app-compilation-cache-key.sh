#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Compute Xcode compilation cache key". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
# The key is OS, arch and toolchain. An owned mini (runner
# <member>-glaeda[-K]) runs the same Xcode build as an ephemeral
# runner but compiles in another workspace path, so its cache
# entries would mostly miss there and push the ephemeral entry out
# of the prefix restore. Fold its workspace path into the toolchain
# hash: each lineage restores only its own, and the ephemeral key is
# unchanged.
identity="$(xcodebuild -version)"
case "${RUNNER_NAME:-}" in
  *-glaeda | *-glaeda-[0-9]*)
    identity="$identity"$'\n'"owned-workspace:$GITHUB_WORKSPACE"
    if [ "${CACHE_KEY_TRACK}" = nightly-next ]; then identity="$identity"$'\n'"track:nightly-next"; fi
    ;;
esac
echo "toolchain=$(printf '%s\n' "$identity" | shasum -a 256 | awk '{print $1}')" >> "$GITHUB_OUTPUT"
