#!/usr/bin/env bash
# Capture the native sidebar gallery on a GUI fleet worker.
# Fleet: cmux-ci run --class light --display --script scripts/ci/native-sidebar-gallery.sh --ref SHA \
#   --artifact artifacts/native-sidebar-gallery.tar
set -euo pipefail

export CMUX_TEST_REQUIRE_GUI=1
scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext CmuxNextAppTests/NativeSidebarGalleryTests

test -f Packages/macOS/CmuxNext/native-sidebar-gallery.tar
artifact_path="${CMUX_CI_ARTIFACT_PATH:-artifacts/native-sidebar-gallery.tar}"
mkdir -p "$(dirname "$artifact_path")"
cp Packages/macOS/CmuxNext/native-sidebar-gallery.tar "$artifact_path"
