#!/usr/bin/env bash
# Collects the Ghostty dependency licenses and builds the cmux-next release
# source archive (Ghostty at its submodule revision plus every Zig package the
# build fetches), then verifies both. CI only: it runs zig (`zig build --fetch`),
# which never runs on a maintainer's Mac or the minis.
#
#   build-ghostty-source-archive.sh <out dir> [<build number>]
#
# Writes <out dir>/ghostty-licenses/ (collect-ghostty-licenses.py tree with
# SOURCE-MANIFEST.json) and <out dir>/cmux-next-source-<build>.tar.gz (build
# defaults to the commit's first 11 characters). Builds the archive twice and
# fails unless both are byte-identical. Publishing is a separate, gated step.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <out dir> [<build number>]" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
out="$1"
commit="$(git -C "$ROOT" rev-parse HEAD)"
build="${2:-${commit:0:11}}"
ghostty="$ROOT/ghostty"
revision="$(git -C "$ROOT" rev-parse "HEAD:ghostty")"
[[ "$(git -C "$ghostty" rev-parse HEAD)" == "$revision" ]] || { echo "error: the ghostty submodule is not checked out at $revision" >&2; exit 1; }
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${RUNNER_TEMP:-/tmp}/cmux-ghostty-zig-cache}"
(cd "$ghostty" && zig build --fetch=all)
notices="$ROOT/cmux-tui/build-support/notices/ghostty"
archive_tool="$ROOT/scripts/cmux-next/notices/ghostty_source_archive.py"
rm -rf "$out/ghostty-licenses"
mkdir -p "$out"
python3 "$notices/collect-ghostty-licenses.py" --ghostty-source "$ghostty" --zig-cache "$ZIG_GLOBAL_CACHE_DIR" \
  --output "$out/ghostty-licenses" --revision "$revision" \
  --release-source-offer "$(python3 "$archive_tool" offer)"
python3 "$notices/verify-ghostty-license-bundle.py" --root "$out/ghostty-licenses" --revision "$revision"
archive="$out/cmux-next-source-$build.tar.gz"
args=(--ghostty-source "$ghostty" --zig-cache "$ZIG_GLOBAL_CACHE_DIR" --license-manifest "$out/ghostty-licenses/SOURCE-MANIFEST.json"
  --revision "$revision" --cmux-commit "$commit" --tag "cmux-next-src-${commit:0:11}")
python3 "$archive_tool" build "${args[@]}" --out "$archive"
python3 "$archive_tool" build "${args[@]}" --out "$archive.again"
cmp "$archive" "$archive.again" || { echo "error: two builds of the source archive differ" >&2; exit 1; }
rm -f "$archive.again"
python3 "$archive_tool" verify --archive "$archive" --license-manifest "$out/ghostty-licenses/SOURCE-MANIFEST.json" --revision "$revision"
shasum -a 256 "$archive"
