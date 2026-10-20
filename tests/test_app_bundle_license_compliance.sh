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

echo "PASS: app bundle license compliance verifier rejects incomplete artifacts"
