#!/usr/bin/env bash
# The stable release DMG is re-encoded from create-dmg's LZFSE (ULFO) image to
# LZMA (ULMO) before it is signed and notarized, as nightly already does in
# scripts/ci/notarize-nightly-dmg.sh. Measured on v0.65.0: 298 MB -> 226 MB.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"

line_of() {
  { grep -n -F -- "$1" "$WORKFLOW" || true; } | head -1 | cut -d: -f1
}

create_line="$(line_of 'create-dmg \')"
convert_line="$(line_of 'hdiutil convert')"
format_line="$(line_of 'Expected ULMO')"
sign_line="$({ grep -n -E 'codesign --force --timestamp --keychain build.keychain' "$WORKFLOW" || true; } | awk -F: -v after="${create_line:-0}" '$1 > after {print $1; exit}')"

if [ -z "$create_line" ] || [ -z "$sign_line" ]; then
  echo "FAIL: release.yml no longer has the create-dmg and DMG codesign steps this test expects" >&2
  exit 1
fi
if [ -z "$convert_line" ] || ! grep -Eq 'hdiutil convert .*-format ULMO' "$WORKFLOW"; then
  echo "FAIL: release.yml must re-encode the release DMG to ULMO (LZMA)" >&2
  exit 1
fi
if [ -z "$format_line" ]; then
  echo "FAIL: release.yml must verify the converted DMG format is ULMO" >&2
  exit 1
fi
if [ "$convert_line" -le "$create_line" ] || [ "$convert_line" -ge "$sign_line" ]; then
  echo "FAIL: the ULMO conversion must run after create-dmg and before the DMG is signed (create=$create_line convert=$convert_line sign=$sign_line)" >&2
  exit 1
fi

echo "PASS: release DMG is converted to ULMO before signing"
