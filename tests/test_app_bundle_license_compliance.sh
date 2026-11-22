#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERIFIER="$ROOT_DIR/scripts/verify-app-bundle-licenses.sh"
TMP_DIR="$(mktemp -d)"
APP_PATH="$TMP_DIR/cmux.app"
RESOURCES_PATH="$APP_PATH/Contents/Resources"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$RESOURCES_PATH"
cp "$ROOT_DIR/LICENSE" "$RESOURCES_PATH/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_LICENSES.md" "$RESOURCES_PATH/THIRD_PARTY_LICENSES.md"

"$VERIFIER" "$APP_PATH"

rm "$RESOURCES_PATH/LICENSE"
if "$VERIFIER" "$APP_PATH" >/dev/null 2>&1; then
  echo "FAIL: verifier accepted an app without the cmux project license" >&2
  exit 1
fi

cp "$ROOT_DIR/LICENSE" "$RESOURCES_PATH/LICENSE"
printf '\nmodified\n' >> "$RESOURCES_PATH/LICENSE"
if "$VERIFIER" "$APP_PATH" >/dev/null 2>&1; then
  echo "FAIL: verifier accepted a project license that differs from the repository license" >&2
  exit 1
fi

cp "$ROOT_DIR/LICENSE" "$RESOURCES_PATH/LICENSE"
rm "$RESOURCES_PATH/THIRD_PARTY_LICENSES.md"
if "$VERIFIER" "$APP_PATH" >/dev/null 2>&1; then
  echo "FAIL: verifier accepted an app without third-party licenses" >&2
  exit 1
fi

cp "$ROOT_DIR/THIRD_PARTY_LICENSES.md" "$RESOURCES_PATH/THIRD_PARTY_LICENSES.md"
mkdir -p "$RESOURCES_PATH/bin"
printf '\xcf\xfa\xed\xfe\x0c\x00\x00\x01' > "$RESOURCES_PATH/bin/unmapped-helper"
if "$VERIFIER" "$APP_PATH" >/dev/null 2>&1; then
  echo "FAIL: verifier accepted a Mach-O that no bundle-map entry covers" >&2
  exit 1
fi
rm "$RESOURCES_PATH/bin/unmapped-helper"

# A mapped Mach-O passes only when the repository notices carry its section.
# The server helper needs first-party notices only; bin/cmux also needs the
# Rust and Zig standard library notices, which a fixture Mach-O cannot name.
mkdir -p "$RESOURCES_PATH/libexec"
printf '\xcf\xfa\xed\xfe\x0c\x00\x00\x01' > "$RESOURCES_PATH/libexec/cmux-server-helper"
"$VERIFIER" "$APP_PATH"

# A bundled Ghostty license tree must verify (bundle-map.json resources entry).
mkdir -p "$RESOURCES_PATH/ghostty-licenses"
printf '{}\n' > "$RESOURCES_PATH/ghostty-licenses/SOURCE-MANIFEST.json"
if "$VERIFIER" "$APP_PATH" >/dev/null 2>&1; then
  echo "FAIL: verifier accepted a Ghostty license tree that does not verify" >&2
  exit 1
fi
rm -rf "$RESOURCES_PATH/ghostty-licenses"

python3 "$ROOT_DIR/scripts/cmux-next/notices/test_check_bundle_notices.py"

echo "PASS: app bundle license compliance verifier rejects incomplete artifacts"
