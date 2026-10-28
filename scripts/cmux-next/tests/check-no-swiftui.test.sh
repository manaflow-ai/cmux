#!/usr/bin/env bash
# check-no-swiftui.py (NO-SWIFTUI): a macOS file that imports SwiftUI outside
# the allowlist fails, a stale allowlist entry fails, an AppKit file passes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-no-swiftui.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-no-swiftui.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
LIST=scripts/cmux-next/no-swiftui-allowlist.txt
SRC=Packages/macOS/CmuxNext/Sources

# check PATH SOURCE ALLOWLIST: runs the guard on a repo root (not a git
# checkout) whose only source is SOURCE at PATH.
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")" "$tmp/repo/$(dirname "$LIST")"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  printf '%s' "$3" > "$tmp/repo/$LIST"
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  return "$code"
}
pass() { check "$1" "$3" "${4:-}" || { echo "FAIL: must pass: $2" >&2; cat "$tmp/err" >&2; exit 1; }; }
fail() {
  local code=0
  check "$1" "$3" "${4:-}" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $2" >&2; cat "$tmp/err" >&2; exit 1; }
}

fail "$SRC/CmuxNextApp/X.swift" "a plain import" $'import AppKit\nimport SwiftUI'
fail "$SRC/CmuxNextApp/X.swift" "a public import" 'public import SwiftUI'
fail "$SRC/CmuxNextApp/X.swift" "a preconcurrency import" '@preconcurrency import SwiftUI'
fail "$SRC/CmuxNextApp/X.swift" "a scoped import" 'import struct SwiftUI.Color'
fail "$SRC/CmuxNextApp/X.swift" "a stale allowlist entry" 'import AppKit' "$SRC/CmuxNextApp/X.swift"
fail "$SRC/CmuxNextApp/X.swift" "an entry for a missing file" 'import AppKit' "$SRC/CmuxNextApp/Gone.swift"
fail "Packages/macOS/CmuxNext/Tests/T/XTests.swift" "a test file" 'import SwiftUI'

fail "$SRC/CmuxNextApp/New/X.swift" "a moved file whose entry still names its old path" 'import SwiftUI' "$SRC/CmuxNextApp/Old/X.swift"
grep -q "change the line to the new path" "$tmp/err" \
  || { echo "FAIL: a gone entry whose file moved names the new path" >&2; cat "$tmp/err" >&2; exit 1; }

pass "$SRC/CmuxNextApp/X.swift" "AppKit only" $'import AppKit\nimport QuartzCore'
pass "$SRC/CmuxNextApp/X.swift" "an allowlisted file" 'import SwiftUI' "$SRC/CmuxNextApp/X.swift"
pass "$SRC/CmuxNextApp/X.swift" "an import in a comment" $'import AppKit\n// import SwiftUI\n/* import SwiftUI */'
pass "$SRC/CmuxNextApp/X.swift" "a SwiftUIish module name" 'import SwiftUIIntrospect'
pass "Packages/iOS/X.swift" "iOS is out of scope" 'import SwiftUI'

# --base: a new entry fails, a moved file keeps its entry, a removed entry passes.
repo="$tmp/git"
rm -rf "$repo"; mkdir -p "$repo/$SRC/A" "$repo/$(dirname "$LIST")"
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'import SwiftUI\nstruct One {}\n' > "$repo/$SRC/A/One.swift"
printf 'import SwiftUI\nstruct Two {}\n' > "$repo/$SRC/A/Two.swift"
printf '%s\n' "$SRC/A/One.swift" "$SRC/A/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m base
base=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$repo/$SRC/B"
git -C "$repo" mv "$SRC/A/One.swift" "$SRC/B/One.swift"
printf '%s\n' "$SRC/A/Two.swift" "$SRC/B/One.swift" > "$repo/$LIST"
git -C "$repo" add -A
python3 -I "$CHECK" --base "$base" "$repo" >/dev/null 2>"$tmp/err" \
  || { echo "FAIL: must pass: a moved file keeps its entry" >&2; cat "$tmp/err" >&2; exit 1; }
printf 'import SwiftUI\nstruct Three {}\n' > "$repo/$SRC/B/Three.swift"
printf '%s\n' "$SRC/A/Two.swift" "$SRC/B/One.swift" "$SRC/B/Three.swift" > "$repo/$LIST"
git -C "$repo" add -A
code=0; python3 -I "$CHECK" --base "$base" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "Three.swift is new since" "$tmp/err" \
  || { echo "FAIL: must fail: a new allowlist entry (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
# A move that also rewrote the file (below git's rename similarity, 84b3fc57) keeps its entry too.
git -C "$repo" rm -q --cached "$SRC/B/Three.swift"; rm "$repo/$SRC/B/Three.swift"
mkdir -p "$repo/$SRC/C"
git -C "$repo" mv "$SRC/A/Two.swift" "$SRC/C/Two.swift"
printf 'import SwiftUI\nimport AppKit\n\n/// Rewritten while it moved.\nstruct Renamed { let a = 1; let b = 2; let c = 3 }\n' > "$repo/$SRC/C/Two.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
python3 -I "$CHECK" --base "$base" "$repo" >/dev/null 2>"$tmp/err" \
  || { echo "FAIL: must pass: a moved and rewritten file keeps its entry" >&2; cat "$tmp/err" >&2; exit 1; }

# One gone entry pairs with one added entry of its name, never with two.
commit() { git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m "$1"; }
mkdir -p "$repo/$SRC/D" "$repo/$SRC/E" "$repo/$SRC/F"
printf 'import SwiftUI\nstruct Dup {}\n' > "$repo/$SRC/D/Dup.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/D/Dup.swift" > "$repo/$LIST"
commit base2
base2=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" rm -q "$SRC/D/Dup.swift"
printf 'import SwiftUI\nstruct E { let e = "a different file" }\n' > "$repo/$SRC/E/Dup.swift"
printf 'import SwiftUI\nstruct F { let f = "another different file" }\n' > "$repo/$SRC/F/Dup.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/E/Dup.swift" "$SRC/F/Dup.swift" > "$repo/$LIST"
git -C "$repo" add -A
code=0; python3 -I "$CHECK" --base "$base2" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "E/Dup.swift is new since" "$tmp/err" && grep -q "F/Dup.swift is new since" "$tmp/err" \
  || { echo "FAIL: must fail: one gone entry cannot admit two new files of its name (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }

# An entry for a file that already imported SwiftUI at the base (a base red) is a note, not growth.
git -C "$repo" rm -q -f "$SRC/E/Dup.swift" "$SRC/F/Dup.swift"
mkdir -p "$repo/$SRC/D"; printf 'import SwiftUI\nstruct Red {}\n' > "$repo/$SRC/D/Red.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
commit base3-red
base3=$(git -C "$repo" rev-parse HEAD)
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/D/Red.swift" > "$repo/$LIST"
git -C "$repo" add -A
python3 -I "$CHECK" --base "$base3" "$repo" >/dev/null 2>"$tmp/err" && grep -q "Red.swift is new in .* but already imported SwiftUI" "$tmp/err" \
  || { echo "FAIL: must pass with a note: an entry for a base red" >&2; cat "$tmp/err" >&2; exit 1; }
echo "check-no-swiftui: ok"
