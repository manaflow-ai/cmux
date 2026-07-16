#!/bin/sh
set -eu

MARKDOWN_VIEWER_DIR="${1:-${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/markdown-viewer}"

if [ ! -d "$MARKDOWN_VIEWER_DIR" ]; then
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to compress markdown viewer assets" >&2
  exit 1
fi

python3 - "$MARKDOWN_VIEWER_DIR" <<'PY'
import pathlib
import sys
import zlib

root = pathlib.Path(sys.argv[1])
file_url_assets = {
    "webviews-app/main.mjs",
    "webviews-app/chunks/agentSessionSurface.mjs",
    "webviews-app/chunks/installWebviewStyles.mjs",
    "webviews-app/chunks/vendor.mjs",
}

for path in sorted(root.rglob("*")):
    if path.suffix not in {".js", ".mjs"}:
        continue
    if path.name.endswith(".deflate"):
        continue
    raw = path.read_bytes()
    compressed = zlib.compress(raw, level=9)
    output = path.with_name(path.name + ".deflate")
    output.write_bytes(compressed)
    relative_path = path.relative_to(root).as_posix()
    if relative_path not in file_url_assets:
        path.unlink()
    print(
        f"compressed markdown viewer asset: {relative_path} -> "
        f"{output.name} ({len(raw)} -> {len(compressed)} bytes)"
    )
PY
