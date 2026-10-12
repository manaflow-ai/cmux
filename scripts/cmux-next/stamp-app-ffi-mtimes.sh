#!/usr/bin/env bash
# Stamps every file and directory of an app FFI xcframework with the FFI source
# commit time, in UTC, before the release zips it (cx-vqwl).
#
#   scripts/cmux-next/stamp-app-ffi-mtimes.sh <xcframework dir> <source commit>
#
# Run inside the git checkout that holds <source commit>. One commit always
# gives the same mtimes, so a rerun gives the same zip bytes. A new commit gives
# the headers a new mtime, so a warm tree rebuilds the Clang module after a pin
# change; the old fixed 1980 stamp made it reuse a stale .pcm (cx-4ncv).
set -euo pipefail

xcf="${1:?usage: stamp-app-ffi-mtimes.sh <xcframework dir> <source commit>}"
commit="${2:?usage: stamp-app-ffi-mtimes.sh <xcframework dir> <source commit>}"
[[ -d "$xcf" ]] || { echo "error: $xcf is not a directory" >&2; exit 1; }

epoch="$(git log -1 --format=%ct "$commit")"
[[ "$epoch" =~ ^[0-9]+$ ]] || { echo "error: no commit time for $commit" >&2; exit 1; }
# touch -t reads local time: format and apply in UTC on BSD and GNU alike.
stamp="$(TZ=UTC date -u -d "@$epoch" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC date -u -r "$epoch" +%Y%m%d%H%M.%S)"
find "$xcf" -exec env TZ=UTC touch -t "$stamp" {} +
echo "app FFI mtimes: $xcf stamped $stamp UTC (commit $commit)"
