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

BROTLI_BIN="${BROTLI_BIN:-}"
BROTLI_BIN_WAS_SET=0
if [ -n "$BROTLI_BIN" ]; then
  BROTLI_BIN_WAS_SET=1
  if resolved_brotli="$(command -v "$BROTLI_BIN" 2>/dev/null)" && [ -x "$resolved_brotli" ]; then
    BROTLI_BIN="$resolved_brotli"
  elif [ ! -x "$BROTLI_BIN" ]; then
    BROTLI_BIN=""
  fi
fi
if [ -z "$BROTLI_BIN" ] && [ "$BROTLI_BIN_WAS_SET" = 0 ]; then
  for candidate in "$(command -v brotli 2>/dev/null || true)" /opt/homebrew/bin/brotli /usr/local/bin/brotli; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      BROTLI_BIN="$candidate"
      break
    fi
  done
fi

python3 - "$MARKDOWN_VIEWER_DIR" "$BROTLI_BIN" <<'PY'
import itertools
import os
import pathlib
import subprocess
import sys
import gzip
import zlib

root = pathlib.Path(sys.argv[1])
brotli_bin = sys.argv[2] or None

def sidecar_is_current(source, output):
    try:
        source_stat = source.stat()
        output_stat = output.stat()
    except FileNotFoundError:
        return False
    return output_stat.st_size > 0 and output_stat.st_mtime_ns >= source_stat.st_mtime_ns

def sync_sidecar_mtime(source, output):
    source_stat = source.stat()
    os.utime(output, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))

for path in sorted(root.glob("*.js")):
    raw = path.read_bytes()
    compressor = zlib.compressobj(9, zlib.DEFLATED, -zlib.MAX_WBITS)
    compressed = compressor.compress(raw) + compressor.flush()
    output = path.with_name(path.name + ".deflate")
    output.write_bytes(compressed)
    path.unlink()
    print(f"compressed markdown viewer asset: {path.name} -> {output.name} ({len(raw)} -> {len(compressed)} bytes)")

diff_viewer_root = root / "diff-viewer"
if diff_viewer_root.is_dir():
    count = 0
    raw_bytes = 0
    compressed_bytes = 0
    seen_outputs = set()
    module_paths = sorted(diff_viewer_root.rglob("*.mjs"))
    for path in module_paths:
        output = path.with_name(path.name + ".gz")
        if not sidecar_is_current(path, output):
            raw = path.read_bytes()
            compressed = gzip.compress(raw, compresslevel=9, mtime=0)
            output.write_bytes(compressed)
            sync_sidecar_mtime(path, output)
        seen_outputs.add(output)
        count += 1
        raw_bytes += path.stat().st_size
        compressed_bytes += output.stat().st_size
    for output in sorted(diff_viewer_root.rglob("*.mjs.gz")):
        if output not in seen_outputs:
            output.unlink()
    if count:
        print(f"compressed diff viewer assets: {count} modules ({raw_bytes} -> {compressed_bytes} bytes)")
    brotli_outputs = {path.with_name(path.name + ".br") for path in module_paths}
    if brotli_bin and module_paths:
        brotli_inputs = [
            path
            for path in module_paths
            if not sidecar_is_current(path, path.with_name(path.name + ".br"))
        ]
        iterator = iter(brotli_inputs)
        while True:
            batch = list(itertools.islice(iterator, 64))
            if not batch:
                break
            subprocess.run(
                [brotli_bin, "-f", "-q", "11", "--", *[str(path) for path in batch]],
                check=True,
            )
            for path in batch:
                output = path.with_name(path.name + ".br")
                if output.exists():
                    sync_sidecar_mtime(path, output)
        for output in sorted(diff_viewer_root.rglob("*.mjs.br")):
            if output not in brotli_outputs:
                output.unlink()
        brotli_bytes = sum(output.stat().st_size for output in brotli_outputs if output.exists())
        print(f"brotli-compressed diff viewer assets: {len(brotli_outputs)} modules ({raw_bytes} -> {brotli_bytes} bytes, refreshed {len(brotli_inputs)})")
    else:
        stale_brotli_outputs = sorted(diff_viewer_root.rglob("*.mjs.br"))
        for output in stale_brotli_outputs:
            output.unlink()
        if stale_brotli_outputs:
            print(f"removed stale diff viewer Brotli assets: {len(stale_brotli_outputs)}")
PY
