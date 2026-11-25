#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly: "Embed verified SSH daemon manifest". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input. An unsigned resume
# checks out an older build commit, so the step runs this script from .nightly-signing-control when that tree lacks it.
bundle_args=()
if [[ "$BUNDLE_REMOTE_DAEMON_ASSETS" == "true" ]]; then
  # Unpublished dogfood builds must work without GitHub release URLs.
  bundle_args+=(--bundle-assets)
fi
# No --verify-cli here: this job holds signing secrets and runs no
# bundle code. verify-signed-nightly runs the bundled-CLI query on the
# signed app.
python3 scripts/verify_remote_daemon_release.py \
  --manifest "remote-daemon-assets/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json" \
  --assets-dir remote-daemon-assets \
  --app "$CHANNEL_APP_PATH" --embed "${bundle_args[@]}"
