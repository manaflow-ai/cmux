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
import hashlib
import json
import pathlib
import sys
import zlib

root = pathlib.Path(sys.argv[1])

for path in sorted(root.rglob("*")):
    if path.suffix not in {".js", ".mjs"}:
        continue
    if path.name.endswith(".deflate"):
        continue
    raw = path.read_bytes()
    compressed = zlib.compress(raw, level=9)
    output = path.with_name(path.name + ".deflate")
    output.write_bytes(compressed)
    path.unlink()
    print(f"compressed markdown viewer asset: {path.name} -> {output.name} ({len(raw)} -> {len(compressed)} bytes)")

for relative_root in ("diff-viewer", "webviews-app", "diff-viewer-app"):
    asset_root = root / relative_root
    if not asset_root.is_dir():
        continue
    files = []
    digest = hashlib.sha256()
    for path in sorted(asset_root.rglob("*")):
        if not path.is_file() or path.suffix != ".deflate":
            continue
        stored_path = path.relative_to(asset_root).as_posix()
        logical_path = stored_path[:-len(".deflate")]
        if pathlib.PurePosixPath(logical_path).suffix not in {".js", ".mjs"}:
            continue
        contents = path.read_bytes()
        digest.update(logical_path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(contents)
        files.append({"logicalPath": logical_path, "storedPath": stored_path})
    if not files:
        continue
    manifest = {
        "version": 1,
        "contentKey": digest.hexdigest(),
        "files": files,
    }
    manifest_path = asset_root / ".cmux-asset-manifest.json"
    manifest_path.write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
    print(f"wrote markdown viewer asset manifest: {relative_root} ({len(files)} files)")
PY
