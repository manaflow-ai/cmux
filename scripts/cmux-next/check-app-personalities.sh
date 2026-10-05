#!/usr/bin/env bash
# Fails when the linked cmux app binary carries more than three personality
# routines in its compact-unwind info: Apple's compact unwind encodes at most
# three per image, and the link already fails above that ("Too many
# personality routines for compact unwind to encode"). The app's budget is
# C++, iroh-ffi and CCmuxAppFFI (2026-10-05 decision: every in-tree Rust C ABI
# joins cmux-tui/crates/cmux-app-ffi; never another Rust static library).
#
#   scripts/cmux-next/check-app-personalities.sh <path to .app or Mach-O>
set -euo pipefail

target="${1:?usage: check-app-personalities.sh <path to .app or Mach-O>}"
images=()
if [[ -d "$target" ]]; then
  name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$target/Contents/Info.plist")"
  images+=("$target/Contents/MacOS/$name")
  # Debug builds keep the code in "<name>.debug.dylib" beside a stub executable.
  [[ -f "$target/Contents/MacOS/$name.debug.dylib" ]] && images+=("$target/Contents/MacOS/$name.debug.dylib")
else
  images+=("$target")
fi

limit=3
status=0
checked=0
for binary in "${images[@]}"; do
[[ -f "$binary" ]] || { echo "error: no binary at $binary" >&2; exit 2; }
for arch in $(lipo -archs "$binary"); do
  info="$(xcrun objdump --macho --unwind-info --arch="$arch" "$binary" 2>&1 || true)"
  count="$(grep -m1 -E 'Personality functions: \(count = [0-9]+\)' <<<"$info" | grep -oE '[0-9]+' | tail -n 1)"
  if [[ -z "$count" ]]; then
    echo "error: $arch: objdump printed no personality table for $binary:" >&2
    head -n 5 <<<"$info" >&2
    status=1
    continue
  fi
  echo "$(basename "$binary") $arch: $count personality routine(s) (limit $limit)"
  (( count > 0 )) && checked=1
  awk '
    /Personality functions:/ { in_table = 1 }
    in_table && lines < 8 { print; lines++ }
    in_table && /^$/ { exit }
  ' <<<"$info"
  if (( count > limit )); then
    echo "error: $(basename "$binary") $arch has $count personality routines; compact unwind holds $limit. Join new Rust C ABIs to cmux-tui/crates/cmux-app-ffi instead of linking another Rust static library (decision 2026-10-05)." >&2
    status=1
  fi
done
done
# A Rust or C++ image always has personality routines; none at all means the
# check read the wrong image.
(( checked == 1 )) || { echo "error: no image of $target has a personality table; wrong path?" >&2; status=1; }
exit "$status"
