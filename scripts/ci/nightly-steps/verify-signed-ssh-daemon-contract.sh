#!/usr/bin/env bash
# nightly.yml verify-signed-nightly: "Verify signed app SSH daemon contract". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
bundle_args=()
if [[ "$BUNDLE_REMOTE_DAEMON_ASSETS" == "true" ]]; then
  bundle_args+=(--require-bundled-assets)
fi
# cmux-next bundles the Rust CLI (#16174), which has no classic
# `remote-daemon-status` command, so nightly-next checks the manifest
# and daemon bytes but skips the bundled-CLI query.
if [[ "$CHANNEL_RELEASE_TAG" == "nightly-next" ]]; then
  echo "nightly-next: skipping --verify-cli (Rust CLI has no remote-daemon-status)"
else
  bundle_args+=(--verify-cli)
fi
python3 scripts/verify_remote_daemon_release.py \
  --manifest "remote-daemon-assets/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json" \
  --assets-dir remote-daemon-assets \
  --app "$CHANNEL_APP_PATH" "${bundle_args[@]}"
