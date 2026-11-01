#!/usr/bin/env bash
# nightly.yml build-nightly-remote-daemon: "Build immutable SSH daemon assets once for every app variant". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
# build-nightly-app's remote_daemon formula; the app's version is $(MARKETING_VERSION).
project_version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([0-9.]*\);$/\1/p' cmux.xcodeproj/project.pbxproj | sort -u)"
VERSION="$(python3 scripts/ci/nightly_version.py marketing --track "$TRACK" \
  --project-version "$project_version" --build "$BUILD" --next-base "$(python3 scripts/ci/nightly_version.py next-base)")"
./scripts/build_remote_daemon_release_assets.sh \
  --version "$VERSION" --release-tag "$RELEASE_TAG" \
  --repo "$GITHUB_REPOSITORY" --asset-suffix "$BUILD" --output-dir remote-daemon-assets
