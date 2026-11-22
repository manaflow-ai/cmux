#!/usr/bin/env bash
# The app FFI release stamps every file and directory of the xcframework with
# the FFI source commit time (UTC) before it zips it (cx-vqwl). A fixed 1980
# stamp gave every release the same header mtimes, so a warm tree reused a
# stale Clang .pcm after a pin change (CMUX_RD_INPUT_PACKET_MAX missing,
# cx-4ncv). Two runs of one commit must give byte-identical zips; two commits
# must give different header mtimes. A non-UTC TZ proves the stamp is UTC.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
stamp="$root/scripts/cmux-next/stamp-app-ffi-mtimes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export TZ=America/Los_Angeles

fail() { echo "FAIL: $*" >&2; exit 1; }
mtime() { python3 -I -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }
zipit() { # $1 = parent dir, $2 = output zip
  if command -v ditto >/dev/null 2>&1; then
    (cd "$1" && ditto -c -k --keepParent CCmuxAppFFI.xcframework "$2")
  else
    python3 -I - "$1" "$2" <<'PY'
import os, sys, zipfile
parent, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirs, files in os.walk(os.path.join(parent, "CCmuxAppFFI.xcframework")):
        dirs.sort()
        for name in sorted(dirs + files):
            path = os.path.join(dirpath, name)
            z.write(path, os.path.relpath(path, parent))
PY
  fi
}

# A repository with two commits at known UTC times.
repo="$work/repo"
git init -q "$repo"
c1_epoch=1759920000 # 2025-10-08T10:40:00Z
c2_epoch=1759923601 # 2025-10-08T11:40:01Z (odd second)
GIT_COMMITTER_DATE="@$c1_epoch +0000" GIT_AUTHOR_DATE="@$c1_epoch +0000" \
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
c1="$(git -C "$repo" rev-parse HEAD)"
GIT_COMMITTER_DATE="@$c2_epoch +0000" GIT_AUTHOR_DATE="@$c2_epoch +0000" \
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
c2="$(git -C "$repo" rev-parse HEAD)"

make_xcf() { # $1 = parent dir
  local h="$1/CCmuxAppFFI.xcframework/macos-arm64_x86_64/Headers/CCmuxRdFFI"
  mkdir -p "$h"
  printf '#define CMUX_RD_INPUT_PACKET_MAX 4096\n' > "$h/cmux_rd_ffi.h"
  printf 'module CCmuxRdFFI { header "cmux_rd_ffi.h" }\n' > "$h/module.modulemap"
  printf 'lib' > "$1/CCmuxAppFFI.xcframework/macos-arm64_x86_64/libcmux_app_ffi.a"
  printf '<plist/>' > "$1/CCmuxAppFFI.xcframework/Info.plist"
}
header="CCmuxAppFFI.xcframework/macos-arm64_x86_64/Headers/CCmuxRdFFI/cmux_rd_ffi.h"

# Run A and run B of commit 1, built at different wall times.
for run in a b; do
  mkdir -p "$work/$run"
  make_xcf "$work/$run"
  [[ "$run" == b ]] && find "$work/$run" -exec touch -t 203001020304.05 {} +
  (cd "$repo" && bash "$stamp" "$work/$run/CCmuxAppFFI.xcframework" "$c1")
  zipit "$work/$run" "$work/$run.zip"
done
cmp -s "$work/a.zip" "$work/b.zip" || fail "two runs of commit $c1 gave different zip bytes"

# Every file and directory inside carries the commit-1 time, in UTC.
while IFS= read -r path; do
  [[ "$(mtime "$path")" == "$c1_epoch" ]] || fail "$path has mtime $(mtime "$path"), want $c1_epoch"
done < <(find "$work/a/CCmuxAppFFI.xcframework")

# Commit 2 gives the headers a different mtime (its own commit time).
mkdir -p "$work/c"
make_xcf "$work/c"
(cd "$repo" && bash "$stamp" "$work/c/CCmuxAppFFI.xcframework" "$c2")
[[ "$(mtime "$work/c/$header")" == "$c2_epoch" ]] || fail "commit 2 header mtime $(mtime "$work/c/$header"), want $c2_epoch"
[[ "$(mtime "$work/c/$header")" != "$(mtime "$work/a/$header")" ]] || fail "two commits gave the same header mtime"

echo "stamp-app-ffi-mtimes.test.sh: ok"
