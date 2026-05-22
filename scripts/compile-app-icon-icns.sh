#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: compile-app-icon-icns.sh <AppIcon.appiconset> <output.icns>

Compiles a macOS .appiconset directory into an .icns file for release variants
that mutate Info.plist after the base Xcode build.
EOF
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

APPICONSET="$1"
OUT_PATH="$2"

if [[ ! -d "$APPICONSET" ]]; then
  echo "error: app icon set not found at $APPICONSET" >&2
  exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
  echo "error: iconutil is required" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 - "$APPICONSET" "$ICONSET_DIR" <<'PY'
import json
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1])
dest = Path(sys.argv[2])
contents = json.loads((source / "Contents.json").read_text(encoding="utf-8"))

for image in contents.get("images", []):
    if image.get("idiom") != "mac":
        continue
    filename = image.get("filename")
    size = image.get("size")
    scale = image.get("scale")
    if not filename or not size or not scale:
        continue

    point_size = size.split("x", 1)[0]
    suffix = "@2x" if scale == "2x" else ""
    src = source / filename
    dst = dest / f"icon_{point_size}x{point_size}{suffix}.png"
    if not src.is_file():
        raise SystemExit(f"missing icon source: {src}")
    shutil.copyfile(src, dst)
PY

mkdir -p "$(dirname "$OUT_PATH")"
iconutil -c icns "$ICONSET_DIR" -o "$OUT_PATH"
if [[ ! -s "$OUT_PATH" ]]; then
  echo "error: failed to create $OUT_PATH" >&2
  exit 1
fi
