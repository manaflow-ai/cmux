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
#
# bin/cmux links libghostty-vt from the submodule that ghostty-vt-sys's
# build.rs selects, at this commit's gitlink (check_ghostty_vt_notices.py
# --print-source; ghostty-next today). When that is not `ghostty`, the script
# also fetches that tree's Zig packages, writes <out dir>/<submodule>-licenses/
# and puts the tree and its packages in the archive.
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
# zig writes its download temp files below the global cache; it must exist.
mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"
# --fetch=all: every declared package, lazy ones included (a superset of what
# any build of this revision links). Mode "needed" fetched only 1 package in
# dry run 37263884156, because a build fetches its lazy packages while it runs.
(cd "$ghostty" && zig build --fetch=all)
notices="$ROOT/cmux-tui/build-support/notices/ghostty"
archive_tool="$ROOT/scripts/cmux-next/notices/ghostty_source_archive.py"
rm -rf "$out/ghostty-licenses"
mkdir -p "$out"
python3 "$notices/collect-ghostty-licenses.py" --ghostty-source "$ghostty" --zig-cache "$ZIG_GLOBAL_CACHE_DIR" \
  --output "$out/ghostty-licenses" --revision "$revision" \
  --release-source-offer "$(python3 "$archive_tool" offer)"
python3 "$notices/verify-ghostty-license-bundle.py" --root "$out/ghostty-licenses" --revision "$revision"
# The libghostty-vt source of bin/cmux, from this commit's tree (never a constant).
vt_line="$(python3 "$ROOT/scripts/cmux-next/notices/check_ghostty_vt_notices.py" --repo "$ROOT" --print-source | sed -n 's/^libghostty-vt source: //p')"
vt_name="${vt_line%% *}" vt_revision="${vt_line##* }"
[[ -n "$vt_name" && "$vt_revision" =~ ^[0-9a-f]{40}$ ]] || { echo "error: could not resolve the libghostty-vt source" >&2; exit 1; }
echo "libghostty-vt source: $vt_name $vt_revision"
next_build=() next_verify=()
if [[ "$vt_name" != ghostty ]]; then
  vt="$ROOT/$vt_name"
  [[ "$(git -C "$vt" rev-parse HEAD 2>/dev/null)" == "$vt_revision" ]] || { echo "error: the $vt_name submodule is not checked out at $vt_revision" >&2; exit 1; }
  (cd "$vt" && zig build --fetch=all)
  rm -rf "$out/$vt_name-licenses"
  python3 "$notices/collect-ghostty-licenses.py" --ghostty-source "$vt" --zig-cache "$ZIG_GLOBAL_CACHE_DIR" \
    --output "$out/$vt_name-licenses" --revision "$vt_revision" \
    --release-source-offer "$(python3 "$archive_tool" offer)"
  python3 "$notices/verify-ghostty-license-bundle.py" --root "$out/$vt_name-licenses" --revision "$vt_revision"
  next_verify=(--next-name "$vt_name" --next-license-manifest "$out/$vt_name-licenses/SOURCE-MANIFEST.json" --next-revision "$vt_revision")
  next_build=("${next_verify[@]}" --next-source "$vt")
fi
archive="$out/cmux-next-source-$build.tar.gz"
args=(--ghostty-source "$ghostty" --zig-cache "$ZIG_GLOBAL_CACHE_DIR" --license-manifest "$out/ghostty-licenses/SOURCE-MANIFEST.json"
  --revision "$revision" --cmux-commit "$commit" --tag "cmux-next-src-${commit:0:11}" ${next_build[@]+"${next_build[@]}"})
python3 "$archive_tool" build "${args[@]}" --out "$archive"
python3 "$archive_tool" build "${args[@]}" --out "$archive.again"
cmp "$archive" "$archive.again" || { echo "error: two builds of the source archive differ" >&2; exit 1; }
rm -f "$archive.again"
python3 "$archive_tool" verify --archive "$archive" --license-manifest "$out/ghostty-licenses/SOURCE-MANIFEST.json" --revision "$revision" ${next_verify[@]+"${next_verify[@]}"}
shasum -a 256 "$archive"
