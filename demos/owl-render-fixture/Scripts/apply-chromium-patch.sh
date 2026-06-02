#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT_DIR/chromium-patches/aws-m1-ultra-verified-owl-host.json"
CHROMIUM_SRC="${CHROMIUM_SRC:-$HOME/chromium/src}"

usage() {
  cat >&2 <<EOF
usage: $0 [--chromium-src <path>] [--manifest <path>]

Applies the recorded OWL Chromium patch to a clean checkout at the manifest's
base commit. This script refuses to run on a dirty Chromium tree.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --chromium-src)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      CHROMIUM_SRC="$1"
      ;;
    --manifest)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      MANIFEST="$1"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [ ! -d "$CHROMIUM_SRC/.git" ]; then
  echo "missing Chromium checkout: $CHROMIUM_SRC" >&2
  exit 1
fi

read_manifest() {
  /usr/bin/python3 - "$MANIFEST" "$ROOT_DIR" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
print(manifest["chromiumBaseCommit"])
print(root / manifest["patchFile"])
print(manifest["patchSHA256"])
PY
}

manifest_values_file="$(mktemp "${TMPDIR:-/tmp}/owl-chromium-apply.XXXXXX")"
read_manifest > "$manifest_values_file"
EXPECTED_BASE="$(sed -n '1p' "$manifest_values_file")"
PATCH_FILE="$(sed -n '2p' "$manifest_values_file")"
EXPECTED_PATCH_SHA="$(sed -n '3p' "$manifest_values_file")"
rm -f "$manifest_values_file"

actual_patch_sha="$(shasum -a 256 "$PATCH_FILE" | awk '{print $1}')"
if [ "$actual_patch_sha" != "$EXPECTED_PATCH_SHA" ]; then
  echo "patch sha mismatch: expected $EXPECTED_PATCH_SHA got $actual_patch_sha" >&2
  exit 1
fi

if [ -n "$(git -C "$CHROMIUM_SRC" status --porcelain)" ]; then
  echo "Chromium checkout is dirty; refusing to apply patch" >&2
  exit 1
fi

git -C "$CHROMIUM_SRC" checkout --detach "$EXPECTED_BASE"
git -C "$CHROMIUM_SRC" apply "$PATCH_FILE"
"$SCRIPT_DIR/check-chromium-patch.sh" --chromium-src "$CHROMIUM_SRC" --manifest "$MANIFEST" --mode applied
