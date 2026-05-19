#!/usr/bin/env bash
set -euo pipefail

PROJECT_FILE="cmux.xcodeproj/project.pbxproj"

if ! grep -q 'scripts/build-vnc-helper.sh' "$PROJECT_FILE"; then
  echo "FAIL: cmux Xcode project does not invoke scripts/build-vnc-helper.sh" >&2
  exit 1
fi

if ! grep -q 'cmux-vnc-helper' "$PROJECT_FILE"; then
  echo "FAIL: cmux Xcode project does not verify bundled cmux-vnc-helper" >&2
  exit 1
fi

if ! grep -q 'libRoyalVNCKit.dylib' "$PROJECT_FILE"; then
  echo "FAIL: cmux Xcode project does not verify bundled libRoyalVNCKit.dylib" >&2
  exit 1
fi

if ! grep -q 'test_bundled_vnc_helper.sh' .github/workflows/nightly.yml; then
  echo "FAIL: nightly workflow does not verify the bundled VNC helper" >&2
  exit 1
fi

if ! grep -q 'test_bundled_vnc_helper.sh' .github/workflows/release.yml; then
  echo "FAIL: release workflow does not verify the bundled VNC helper" >&2
  exit 1
fi

if ! grep -q 'CMUXVNC' cmux.xcodeproj/project.pbxproj; then
  echo "FAIL: cmux app target is missing the CMUXVNC package dependency" >&2
  exit 1
fi

if ! grep -Fq 'if [[ "$helper" == *.dylib ]]; then' scripts/sign-cmux-bundle.sh; then
  echo "FAIL: sign-cmux-bundle.sh must sign dylibs without helper entitlements" >&2
  exit 1
fi

echo "PASS: VNC helper bundling is wired into project and release workflows"
