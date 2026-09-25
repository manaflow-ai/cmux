#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/5468.
#
# The macOS app's deployment floor must stay aligned with its Swift packages,
# bundled helpers, and Homebrew metadata. A single target that drifts upward
# makes otherwise universal Intel artifacts unlaunchable on supported Macs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_TARGET="13.0"
EXPECTED_SYMBOL=":ventura"
fail=0

deployment_targets="$(
  awk -F '= ' '
    /MACOSX_DEPLOYMENT_TARGET = / {
      gsub(/[;[:space:]]/, "", $2)
      print $2
    }
  ' "$ROOT_DIR/cmux.xcodeproj/project.pbxproj" | sort -u
)"
if [ "$deployment_targets" != "$EXPECTED_TARGET" ]; then
  echo "FAIL: expected one Xcode macOS deployment target $EXPECTED_TARGET, got ${deployment_targets:-<none>}" >&2
  fail=1
fi

while IFS= read -r package_file; do
  [ -n "$package_file" ] || continue
  if rg -n '\.macOS\(\.v14\)' "$package_file" >/dev/null; then
    echo "FAIL: $package_file still requires macOS 14" >&2
    fail=1
  fi
done < <(rg -l 'macOS\(\.v1[34]\)' "$ROOT_DIR/Packages" --glob 'Package.swift' | sort)

for file in \
  "$ROOT_DIR/scripts/build-diff-sidecar.sh" \
  "$ROOT_DIR/scripts/verify-diff-sidecar-artifact.sh" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh" \
  "$ROOT_DIR/scripts/build-plain-text-paste-worker.sh" \
  "$ROOT_DIR/scripts/build-wireguard-go.sh" \
  "$ROOT_DIR/Native/DiffSidecar/README.md" \
  "$ROOT_DIR/.github/workflows/update-homebrew.yml" \
  "$ROOT_DIR/scripts/build-sign-upload.sh"; do
  if rg -n 'macOS 14|macos14|macos: :sonoma|:sonoma|macos-version-min=14\.0|MACOSX_DEPLOYMENT_TARGET:-14\.0|CMUX_DIFF_SIDECAR_MIN_MACOS:-14\.0|minimum 14\.0' "$file" >/dev/null; then
    echo "FAIL: $file still advertises a macOS 14 minimum" >&2
    fail=1
  fi
done

for file in \
  "$ROOT_DIR/.github/workflows/update-homebrew.yml" \
  "$ROOT_DIR/scripts/build-sign-upload.sh"; do
  if ! rg -n "depends_on macos:[[:space:]]*$EXPECTED_SYMBOL" "$file" >/dev/null; then
    echo "FAIL: $file must use the $EXPECTED_SYMBOL Homebrew requirement" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS: macOS minimum target is $EXPECTED_TARGET across app, packages, helpers, and cask metadata"
