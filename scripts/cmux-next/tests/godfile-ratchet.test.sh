#!/usr/bin/env bash
# The god-file ratchet on Swift files and on a push (check-no-godfiles.sh,
# godfile-baseline.tsv, prepush-gate.py's local "god files" rule).
#
# - A Swift file over its line or type budget is a ratchet entry like a type:
#   a listed file may stay at its baseline numbers and never grow; an unlisted
#   one must meet the budget. A clean tree with every over-budget file listed
#   passes, so a new god file stands out instead of joining a standing red.
# - --rev REV measures REV's commit and REV's baseline, never the checkout.
# - --rev with --base: the baseline only lowers; a new or raised row needs a
#   date in its fifth column; a row follow-renames.py moved passes.
# - The pre-push gate runs the check on the push's own files and refuses growth;
#   a range the push does not own pays for its own growth.
# - follow-renames.py moves and checks swift-file rows like swift-type rows.
#
# Not a CI job (Lawrence 2026-10-23: no new CI tests); run it on the fleet:
#   bash scripts/cmux-next/tests/godfile-ratchet.test.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-godfile-ratchet.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; [[ -f "$tmp/out" ]] && cat "$tmp/out" >&2; exit 1; }

repo="$tmp/repo"
pkg="$repo/Packages/macOS/CmuxNext"
scripts="$repo/scripts/cmux-next"
src="$pkg/Sources/Fixture"
header=$'# Ratchet for scripts/cmux-next/check-no-godfiles.sh: entries over budget that may only shrink.\n# kind<TAB>key<TAB>lines<TAB>fns[<TAB>date listed]. Regenerate with --update-baseline (lowers only).'

g() { git -C "$repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
swift_file() { # path lines: a one-type Swift file of exactly LINES lines
  local i
  mkdir -p "$(dirname "$1")"
  { echo "struct $(basename "$1" .swift) {"
    for (( i = 0; i < $2 - 2; i++ )); do echo "  let value$i = $i"; done
    echo "}"; } > "$1"
}
baseline() { # rows...: the fixture's baseline with these rows
  { echo "$header"; for row in "$@"; do printf '%s\n' "$row"; done; } > "$scripts/godfile-baseline.tsv"
}
check() { # args... -> exit status; output in $tmp/out
  env -u GODFILES_WARN_SLACK bash "$scripts/check-no-godfiles.sh" "$@" "$pkg" > "$tmp/out" 2>&1
}
commit() { g add -A; g commit -qm "$1"; g rev-parse HEAD; }

rm -rf "$repo"; mkdir -p "$scripts" "$src"
cp "$ROOT_DIR/scripts/cmux-next/check-no-godfiles.sh" "$scripts/"
g init -q

# --- A listed Swift file: may stay at its baseline, may not grow past it.
swift_file "$src/Big.swift" 500
swift_file "$src/Small.swift" 50
baseline $'swift-file\tSources/Fixture/Big.swift\t500\t1\t20261028'
base_commit="$(commit base)"
check --only swift || fail "a Swift file at its baseline row must pass (every over-budget file listed: no standing red)"
swift_file "$src/Big.swift" 501
check --only swift && fail "a listed Swift file one line past its baseline must fail"
grep -q 'Big.swift has 501 lines; baseline allows 500' "$tmp/out" || fail "the failure must name the baseline it grew past"
swift_file "$src/Big.swift" 500

# --- An unlisted Swift file past its budget fails; a listed file is held to the budget on its other count.
swift_file "$src/Small.swift" 401
check --only swift && fail "an unlisted Swift file past 400 lines must fail"
grep -q 'Small.swift has 401 lines (limit 400)' "$tmp/out" || fail "an unlisted file must name the budget"
swift_file "$src/Small.swift" 50
python3 - "$src/Big.swift" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
# 500 lines and 4 top-level types: three one-line structs replace three value lines.
body = lines[:-4] + ["}", "struct A {}", "struct B {}", "struct C {}"]
open(p, "w").write("\n".join(body) + "\n")
PY
[[ "$(wc -l < "$src/Big.swift" | tr -d ' ')" == 500 ]] || fail "fixture: Big.swift must stay at 500 lines"
check --only swift && fail "a file listed for its lines must still meet the 3-type budget"
grep -q 'declares 4 top-level types (baseline allows 3)' "$tmp/out" || fail "the type count must be held to the budget"
g checkout -q -- "$src/Big.swift"

# --- --update-baseline keeps a swift-file row and its date, and lowers it.
swift_file "$src/Big.swift" 480
bash "$scripts/check-no-godfiles.sh" --update-baseline --only swift "$pkg" > "$tmp/out" 2>&1 && fail "--update-baseline must refuse --only"
env -u GODFILES_WARN_SLACK bash "$scripts/check-no-godfiles.sh" --update-baseline "$pkg" > "$tmp/out" 2>&1 || fail "--update-baseline must run"
grep -qxF $'swift-file\tSources/Fixture/Big.swift\t480\t1\t20261028' "$scripts/godfile-baseline.tsv" ||
  { cat "$scripts/godfile-baseline.tsv" >&2; fail "--update-baseline must lower a swift-file row to 480 and keep its date"; }
g checkout -q -- "$src/Big.swift" "$scripts/godfile-baseline.tsv"

# --- --rev measures the commit, not the checkout.
swift_file "$src/Big.swift" 600
check --only swift --rev HEAD || fail "--rev HEAD must measure the commit (500 lines), not the edited checkout (600)"
check --only swift && fail "the checkout run must still see the 600-line edit"
g checkout -q -- "$src/Big.swift"

# --- The pre-push form: --rev HEAD --base BASE --file PATH.
swift_file "$src/Mid.swift" 390
mid_base="$(commit "mid at 390")"
swift_file "$src/Mid.swift" 410
mid_head="$(commit "mid grows past 400")"
check --rev "$mid_head" --base "$mid_base" --file Packages/macOS/CmuxNext/Sources/Fixture/Mid.swift &&
  fail "a push that takes an unlisted file past 400 lines must fail"
check --rev "$mid_head" --base "$mid_head" --file Packages/macOS/CmuxNext/Sources/Fixture/Mid.swift ||
  fail "a file over budget on the base that this change did not grow must pass"

# --- The baseline only lowers: an undated new row or raise fails; a dated one passes; a moved row passes.
row_base="$(g rev-parse HEAD)"
baseline $'swift-file\tSources/Fixture/Big.swift\t500\t1\t20261028' $'swift-file\tSources/Fixture/Mid.swift\t410\t1'
undated="$(commit "undated row")"
check --rev "$undated" --base "$row_base" --file Packages/macOS/CmuxNext/Sources/Fixture/Mid.swift &&
  fail "a new baseline row without a date must fail"
grep -q 'new row swift-file Sources/Fixture/Mid.swift has no date' "$tmp/out" || fail "the failure must name the undated row"
baseline $'swift-file\tSources/Fixture/Big.swift\t500\t1\t20261028' $'swift-file\tSources/Fixture/Mid.swift\t410\t1\t20261029'
dated="$(commit "dated row")"
check --rev "$dated" --base "$row_base" --file Packages/macOS/CmuxNext/Sources/Fixture/Mid.swift ||
  fail "a new baseline row with a date must pass"
swift_file "$src/Big.swift" 520
baseline $'swift-file\tSources/Fixture/Big.swift\t520\t1\t20261028' $'swift-file\tSources/Fixture/Mid.swift\t410\t1\t20261029'
raised="$(commit "raise without a new date")"
check --rev "$raised" --base "$dated" --file Packages/macOS/CmuxNext/Sources/Fixture/Big.swift &&
  fail "a raised row that keeps its old date must fail"
grep -q 'raised from 500 lines, 1 fns to 520, 1 without a new date' "$tmp/out" || fail "the failure must name the raise"
g reset -q --hard "$dated"
g mv "$src/Big.swift" "$src/Moved.swift"
baseline $'swift-file\tSources/Fixture/Moved.swift\t500\t1' $'swift-file\tSources/Fixture/Mid.swift\t410\t1\t20261029'
sed -i.bak 's/^struct Big /struct Moved /' "$src/Moved.swift"; rm -f "$src/Moved.swift.bak"
moved="$(commit "move Big")"
check --rev "$moved" --base "$dated" --file Packages/macOS/CmuxNext/Sources/Fixture/Moved.swift ||
  fail "a row that only moved with its file (same kind and numbers) must pass"

# --- follow-renames.py: swift-file rows follow a move and a stale one is found.
cp "$ROOT_DIR/scripts/cmux-next/follow-renames.py" "$scripts/"
baseline $'swift-file\tSources/Fixture/Gone.swift\t500\t1\t20261028' $'swift-file\tSources/Fixture/Mid.swift\t410\t1\t20261029'
commit "stale row" > /dev/null
python3 -I "$scripts/follow-renames.py" --repo "$repo" --check > "$tmp/out" 2>&1 && fail "a swift-file row naming no file must be stale"
grep -q 'Sources/Fixture/Gone.swift' "$tmp/out" || fail "--check must name the stale swift-file row"
baseline $'swift-file\tSources/Fixture/Mid.swift\t410\t1\t20261029'
before_move="$(commit "rows")"
g mv "$src/Mid.swift" "$src/Middle.swift"
after_move="$(commit "move Mid")"
python3 -I "$scripts/follow-renames.py" --repo "$repo" --from-git "$before_move..$after_move" > "$tmp/out" 2>&1 ||
  fail "follow-renames.py --from-git must run"
grep -qxF $'swift-file\tSources/Fixture/Middle.swift\t410\t1\t20261029' "$scripts/godfile-baseline.tsv" ||
  { cat "$scripts/godfile-baseline.tsv" >&2; fail "a swift-file row must follow its file's move"; }
g reset -q --hard "$after_move"

# --- prepush-gate.py's local rule: refuses a push that grows a god file; a range it does not own pays for its own.
for f in prepush-gate.py git_batch.py; do cp "$ROOT_DIR/scripts/cmux-next/$f" "$scripts/"; done
baseline
swift_file "$src/Services.swift" 666
swift_file "$src/Other.swift" 100
upstream="$(commit "upstream: Services at 666, unlisted")"
swift_file "$src/Services.swift" 1104
grown="$(commit "branch: Services grows to 1104")"
swift_file "$src/Other.swift" 120
later="$(commit "branch: Other grows inside its budget")"
python3 -I - "$scripts/prepush-gate.py" "$repo" "$upstream" "$grown" "$later" <<'PY' > "$tmp/out" 2>&1 || fail "prepush-gate.py god_files"
import contextlib, importlib.util, io, sys
from pathlib import Path
path, repo, upstream, grown, later = sys.argv[1:]
spec = importlib.util.spec_from_file_location("gate", path)
gate = importlib.util.module_from_spec(spec)
sys.modules["gate"] = gate
spec.loader.exec_module(gate)
class Own:
    def __init__(self, base, head, before=()):
        self.base, self.head, self.before = base, head, tuple(before)
def refused(own):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        result = gate.god_files(Path(repo), [own], Path(path).parent)
    return result, err.getvalue()
result, err = refused(Own(upstream, grown))
assert result, "growing an unlisted 666-line file to 1104 lines must refuse the push:\n" + err
assert "Services.swift has 1104 lines" in err, err
result, err = refused(Own(upstream, later, [(upstream, grown)]))
assert not result, "growth the old remote head already had is not this push's:\n" + err
result, err = refused(Own(grown, later))
assert not result, "a push that grows only a file inside its budget must pass:\n" + err
print("prepush god files: ok")
PY

echo "godfile ratchet: ok"
