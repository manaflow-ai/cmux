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
# A finding the base already had is a base red: a warning, never this change's failure.
# Red.swift imports SwiftUI unlisted at base3 (a push landed it past the gate).
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
out=$(GITHUB_ACTIONS=true python3 -I "$CHECK" --base "$base3" "$repo" 2>"$tmp/err") \
  && grep -q "base red, already on .*D/Red.swift: imports SwiftUI" "$tmp/err" \
  && grep -q "::warning title=No new SwiftUI (base red)::$SRC/D/Red.swift" <<<"$out" \
  || { echo "FAIL: must pass with a warning: an unlisted importer already on the base" >&2; cat "$tmp/err" >&2; exit 1; }
code=0; python3 -I "$CHECK" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] || { echo "FAIL: without --base the base red still fails (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
# The same base red, moved by the change, is still the base's.
mkdir -p "$repo/$SRC/G"; git -C "$repo" mv "$SRC/D/Red.swift" "$SRC/G/Red.swift"
python3 -I "$CHECK" --base "$base3" "$repo" >/dev/null 2>"$tmp/err" \
  || { echo "FAIL: must pass: a base red the change only moved" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" mv "$SRC/G/Red.swift" "$SRC/D/Red.swift"
# A new importer beside the base red is still this change's finding.
printf 'import SwiftUI\nstruct Fresh {}\n' > "$repo/$SRC/D/Fresh.swift"
git -C "$repo" add -A
code=0; python3 -I "$CHECK" --base "$base3" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "^NO-SWIFTUI: $SRC/D/Fresh.swift: imports SwiftUI" "$tmp/err" \
  && ! grep -q "^NO-SWIFTUI: $SRC/D/Red.swift" "$tmp/err" \
  || { echo "FAIL: must fail on the new importer only (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" rm -q -f "$SRC/D/Fresh.swift"
# A change that drops the import from an allowlisted file but keeps its line fails (its own stale entry);
# an entry the base already had stale is a base red.
printf 'import AppKit\nstruct One {}\n' > "$repo/$SRC/B/One.swift"
git -C "$repo" add -A
code=0; python3 -I "$CHECK" --base "$base3" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "^NO-SWIFTUI: $LIST: $SRC/B/One.swift no longer imports SwiftUI" "$tmp/err" \
  || { echo "FAIL: must fail: a stale entry the change made (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
commit base4-stale
base4=$(git -C "$repo" rev-parse HEAD)
python3 -I "$CHECK" --base "$base4" "$repo" >/dev/null 2>"$tmp/err" \
  && grep -q "base red, already on .*B/One.swift no longer imports SwiftUI" "$tmp/err" \
  || { echo "FAIL: must pass with a warning: a stale entry already on the base" >&2; cat "$tmp/err" >&2; exit 1; }
# A change that puts SwiftUI back into a file whose entry the base already had stale fails:
# the entry stops being stale, but the SwiftUI is new.
printf 'import SwiftUI\nstruct One {}\n' > "$repo/$SRC/B/One.swift"
git -C "$repo" add -A
code=0; python3 -I "$CHECK" --base "$base4" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "^NO-SWIFTUI: $SRC/B/One.swift: imports SwiftUI, which it did not at" "$tmp/err" \
  || { echo "FAIL: must fail: new SwiftUI in a file whose entry was stale on the base (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
# The same when the change also moves that file and re-points its entry.
mkdir -p "$repo/$SRC/H"; git -C "$repo" mv "$SRC/B/One.swift" "$SRC/H/One.swift"
printf '%s\n' "$SRC/C/Two.swift" "$SRC/H/One.swift" > "$repo/$LIST"
git -C "$repo" add -A
code=0; python3 -I "$CHECK" --base "$base4" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "^NO-SWIFTUI: $SRC/H/One.swift: imports SwiftUI, which it did not at" "$tmp/err" \
  || { echo "FAIL: must fail: new SwiftUI in a moved file whose entry was stale on the base (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" mv "$SRC/H/One.swift" "$SRC/B/One.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
# A change that unlists a file the base allowed (it still imports SwiftUI) fails.
printf 'import SwiftUI\nstruct One {}\n' > "$repo/$SRC/B/One.swift"
printf '%s\n' "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
code=0; python3 -I "$CHECK" --base "$base4" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "^NO-SWIFTUI: $SRC/B/One.swift: imports SwiftUI" "$tmp/err" \
  || { echo "FAIL: must fail: an importer whose base entry the change deleted (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
# A base red the change moves and lists under its new path is an acknowledged base red, not growth.
# (One.swift goes back to AppKit as at base4: its SwiftUI above was the unlisting case's.)
printf 'import AppKit\nstruct One {}\n' > "$repo/$SRC/B/One.swift"
mkdir -p "$repo/$SRC/G"; git -C "$repo" mv "$SRC/D/Red.swift" "$SRC/G/Red.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/G/Red.swift" > "$repo/$LIST"
git -C "$repo" add -A
python3 -I "$CHECK" --base "$base4" "$repo" >/dev/null 2>"$tmp/err" && grep -q "G/Red.swift is new in .* but already imported SwiftUI" "$tmp/err" \
  || { echo "FAIL: must pass with a note: a moved base red listed under its new path" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" mv "$SRC/G/Red.swift" "$SRC/D/Red.swift"
# Dropping a gone entry while listing a base red of the same file name pairs them as a move, but the
# base red imported SwiftUI at the base: not new SwiftUI.
mkdir -p "$repo/$SRC/J" "$repo/$SRC/K"; printf 'import SwiftUI\nstruct Pair {}\n' > "$repo/$SRC/K/Pair.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/J/Pair.swift" > "$repo/$LIST"
commit base4b-gone-entry
base4b=$(git -C "$repo" rev-parse HEAD)
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/K/Pair.swift" > "$repo/$LIST"
git -C "$repo" add -A
python3 -I "$CHECK" --base "$base4b" "$repo" >/dev/null 2>"$tmp/err" \
  || { echo "FAIL: must pass: a base red listed in place of a gone entry of its name" >&2; cat "$tmp/err" >&2; exit 1; }
# The same when the change also moves the base red (a git rename).
mkdir -p "$repo/$SRC/L"; git -C "$repo" mv "$SRC/K/Pair.swift" "$SRC/L/Pair.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/L/Pair.swift" > "$repo/$LIST"
git -C "$repo" add -A
python3 -I "$CHECK" --base "$base4b" "$repo" >/dev/null 2>"$tmp/err" \
  || { echo "FAIL: must pass: a moved base red listed in place of a gone entry of its name" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" mv "$SRC/L/Pair.swift" "$SRC/K/Pair.swift"
git -C "$repo" rm -q -f "$SRC/K/Pair.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
# A move that rewrote a listed file into a path the base listed but did not have keeps its SwiftUI.
mkdir -p "$repo/$SRC/M" "$repo/$SRC/N"; printf 'import SwiftUI\nstruct Mv {}\n' > "$repo/$SRC/M/Mv.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/M/Mv.swift" "$SRC/N/Mv.swift" > "$repo/$LIST"
commit base4c-listed-destination
base4c=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" rm -q "$SRC/M/Mv.swift"
printf 'import SwiftUI\nimport AppKit\n\n/// Rewritten while it moved.\nstruct Moved { let a = 1; let b = 2; let c = 3 }\n' > "$repo/$SRC/N/Mv.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/N/Mv.swift" > "$repo/$LIST"
git -C "$repo" add -A
python3 -I "$CHECK" --base "$base4c" "$repo" >/dev/null 2>"$tmp/err" \
  || { echo "FAIL: must pass: a rewritten move into a path the base listed" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" rm -q -f "$SRC/N/Mv.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
# An allowlisted symlink to a SwiftUI source, unchanged since the base, passes.
mkdir -p "$repo/$SRC/S"; printf 'import SwiftUI\nstruct Real {}\n' > "$repo/$SRC/S/Real.swift"
ln -s Real.swift "$repo/$SRC/S/Link.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/S/Link.swift" "$SRC/S/Real.swift" > "$repo/$LIST"
commit base4d-symlink
python3 -I "$CHECK" --base "$(git -C "$repo" rev-parse HEAD)" "$repo" >/dev/null 2>"$tmp/err" \
  || { echo "FAIL: must pass: an unchanged allowlisted symlink" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" rm -q -f "$SRC/S/Link.swift" "$SRC/S/Real.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
# A symlink whose target goes through a directory symlink, unchanged since the base, passes.
mkdir -p "$repo/$SRC/S/Real"; printf 'import SwiftUI\nstruct Deep {}\n' > "$repo/$SRC/S/Real/Deep.swift"
ln -s Real "$repo/$SRC/S/Alias"; ln -s Alias/Deep.swift "$repo/$SRC/S/Link.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/S/Alias/Deep.swift" "$SRC/S/Link.swift" "$SRC/S/Real/Deep.swift" > "$repo/$LIST"
commit base4d2-dir-symlink
code=0; python3 -I "$CHECK" --base "$(git -C "$repo" rev-parse HEAD)" "$repo" >/dev/null 2>"$tmp/err" || code=$?
! grep -q "^NO-SWIFTUI: $SRC/S/Link.swift: imports SwiftUI, which it did not" "$tmp/err" \
  || { echo "FAIL: an unchanged symlink through a directory symlink is not new SwiftUI" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" rm -q -f "$SRC/S/Link.swift" "$SRC/S/Alias" "$SRC/S/Real/Deep.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
# One dropped importer cannot vouch for two stale entries of its name.
mkdir -p "$repo/$SRC/P" "$repo/$SRC/Q" "$repo/$SRC/R"
printf 'import SwiftUI\nstruct V {}\n' > "$repo/$SRC/P/View.swift"
printf 'import AppKit\nstruct V1 { let q = 1 }\n' > "$repo/$SRC/Q/View.swift"
printf 'import AppKit\nstruct V2 { let r = "different" }\n' > "$repo/$SRC/R/View.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/P/View.swift" "$SRC/Q/View.swift" "$SRC/R/View.swift" > "$repo/$LIST"
commit base4f-two-stale
base4f=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" rm -q "$SRC/P/View.swift"
printf 'import SwiftUI\nstruct V1 { let q = 1 }\n' > "$repo/$SRC/Q/View.swift"
printf 'import SwiftUI\nstruct V2 { let r = "different" }\n' > "$repo/$SRC/R/View.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/Q/View.swift" "$SRC/R/View.swift" > "$repo/$LIST"
git -C "$repo" add -A
code=0; python3 -I "$CHECK" --base "$base4f" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "^NO-SWIFTUI: $SRC/Q/View.swift: imports SwiftUI, which it did not" "$tmp/err" \
  && grep -q "^NO-SWIFTUI: $SRC/R/View.swift: imports SwiftUI, which it did not" "$tmp/err" \
  || { echo "FAIL: must fail: one dropped importer cannot cover two refilled stale entries (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" rm -q -f "$SRC/Q/View.swift" "$SRC/R/View.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
# A renamed importer cannot also vouch for a stale entry of its name.
mkdir -p "$repo/$SRC/W" "$repo/$SRC/X" "$repo/$SRC/Y"
printf 'import SwiftUI\nstruct W {}\n' > "$repo/$SRC/W/View.swift"
printf 'import AppKit\nstruct Y { let y = "other" }\n' > "$repo/$SRC/Y/View.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/W/View.swift" "$SRC/Y/View.swift" > "$repo/$LIST"
commit base4g-rename-and-stale
base4g=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" mv "$SRC/W/View.swift" "$SRC/X/View.swift"
printf 'import SwiftUI\nstruct Y { let y = "other" }\n' > "$repo/$SRC/Y/View.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/X/View.swift" "$SRC/Y/View.swift" > "$repo/$LIST"
git -C "$repo" add -A
code=0; python3 -I "$CHECK" --base "$base4g" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "^NO-SWIFTUI: $SRC/Y/View.swift: imports SwiftUI, which it did not" "$tmp/err" \
  && ! grep -q "^NO-SWIFTUI: $SRC/X/View.swift" "$tmp/err" \
  || { echo "FAIL: must fail on the refilled entry only: a rename source vouches for nothing else (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" rm -q -f "$SRC/X/View.swift" "$SRC/Y/View.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
# A base source that is not UTF-8 is read, not a crash.
mkdir -p "$repo/$SRC/U"; printf 'import SwiftUI\n// caf\xe9\nstruct U {}\n' > "$repo/$SRC/U/Latin.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" "$SRC/U/Latin.swift" > "$repo/$LIST"
commit base4e-latin1
base4e=$(git -C "$repo" rev-parse HEAD)
printf 'import SwiftUI\n// cafe\nstruct U {}\n' > "$repo/$SRC/U/Latin.swift"
git -C "$repo" add -A
python3 -I "$CHECK" --base "$base4e" "$repo" >/dev/null 2>"$tmp/err" \
  || { echo "FAIL: must pass: a base source that is not UTF-8" >&2; cat "$tmp/err" >&2; exit 1; }
git -C "$repo" rm -q -f "$SRC/U/Latin.swift"
printf '%s\n' "$SRC/B/One.swift" "$SRC/C/Two.swift" > "$repo/$LIST"
git -C "$repo" add -A
# An allowlist already unsorted on the base warns while the change leaves it alone, and fails once the change edits it.
printf '%s\n' "$SRC/C/Two.swift" "$SRC/B/One.swift" > "$repo/$LIST"
commit base5-unsorted
base5=$(git -C "$repo" rev-parse HEAD)
python3 -I "$CHECK" --base "$base5" "$repo" >/dev/null 2>"$tmp/err" && grep -q "base red, already on .*keep it sorted" "$tmp/err" \
  || { echo "FAIL: must pass with a warning: an allowlist already unsorted on the base" >&2; cat "$tmp/err" >&2; exit 1; }
printf '%s\n' "$SRC/C/Two.swift" "$SRC/B/One.swift" "$SRC/B/One.swift" > "$repo/$LIST"
code=0; python3 -I "$CHECK" --base "$base5" "$repo" >/dev/null 2>"$tmp/err" || code=$?
[[ $code -eq 1 ]] && grep -q "^NO-SWIFTUI: $LIST: keep it sorted" "$tmp/err" \
  || { echo "FAIL: must fail: a duplicate added to an allowlist already unsorted (got $code)" >&2; cat "$tmp/err" >&2; exit 1; }
echo "check-no-swiftui: ok"
