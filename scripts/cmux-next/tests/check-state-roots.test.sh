#!/usr/bin/env bash
# check-state-roots.sh (per-build isolation S7, cx-is1kf.8): a new literal
# state root in product code fails, comments and tests pass, the baseline
# admits listed sites only and ratchets down.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-state-roots.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-state-roots.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the guard on a repo root whose only source is $2 at path $1 and whose
# baseline is $3 (may be empty).
check() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")" "$tmp/repo/scripts/cmux-next"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  printf '%b' "${3:-}" > "$tmp/repo/scripts/cmux-next/state-roots-baseline.tsv"
  local code=0
  bash "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  # 0 = clean; 1 = a finding that names the file; anything else is a crash.
  if [[ $code -eq 1 ]] && ! grep -q "$1" "$tmp/err"; then code=3; fi
  return "$code"
}
RS=cmux-tui/crates/fixture/src/lib.rs
SW=Packages/macOS/CmuxNext/Sources/Fixture/Fixture.swift
pass() { check "$1" "$3" "${4:-}" || { echo "FAIL: must pass: $2" >&2; cat "$tmp/err" >&2; exit 1; }; }
fail() {
  local code=0
  check "$1" "$3" "${4:-}" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $2" >&2; cat "$tmp/err" >&2; exit 1; }
}

fail "$SW" "a Swift Chief root" '        home.appendingPathComponent(".cmux/chief/default")'
fail "$SW" "a Swift acpmux root" '        let root = home.appendingPathComponent(".acpmux")'
fail "$SW" "the old mux home" '        home.appending(path: ".cmux/mux/tags")'
fail "$SW" "a split .cmux component" '        home.appendingPathComponent(".cmux").appendingPathComponent("chief")'
fail "$SW" "the shared App Support folder" '        "Library/Application Support/cmux/last-app-cli"'
fail "$SW" "a tag state folder" '        support.appending(path: "cmux/tags/\(tag)/tui")'
fail "$RS" "a Rust acpmux root" '    let home = dirs::home_dir()?.join(".acpmux");'
fail "$RS" "a Rust Chief root" '    home.join(".cmux/chief").join(account)'
fail "$RS" "a Rust build state folder" '    support.join(format!("cmux/builds/{key}/tui"))'
fail "$SW" "a NEXT tag state folder" '        support.appending(path: "cmux-next/tags/\(tag)/tui")'
fail "$RS" "a NEXT build state folder" '    support.join(format!("cmux-next/builds/{key}/tui"))'
fail "$RS" "a NEXT tags folder without a slash" '    support.join("cmux-next/tags")'
pass "$RS" "the NEXT folder name alone" '    support.join("cmux-next")'
pass "$SW" "a comment" '        // never write ~/.acpmux here'
pass "$SW" "a doc comment" '    /// `~/.cmux/chief/<account>` is NIGHTLY'"'"'s'
pass "$RS" "a block comment line" '     * ~/.acpmux is the shared root'
pass "$RS" "a similar word" '    let name = ".acpmuxrc-not-a-root";'
pass "$SW" "a resolver call" '        let root = build.acpmuxHome(userHome: home)'
pass "$RS" "a baselined site" '    home.join(".acpmux")' "$RS\t1\tkeep\tresolver\n"
fail "$RS" "a second site past the baseline" '    home.join(".acpmux")
    home.join(".cmux/chief")' "$RS\t1\tkeep\tresolver\n"
fail "$RS" "a removed site with a stale baseline" '    let x = 1;' "$RS\t1\tmove\tcx-test\n"
fail "$RS" "fewer sites than the baseline" '    home.join(".acpmux")' "$RS\t2\tkeep\tresolver\n"
fail "$RS" "a tags folder without a slash" '    support.join("cmux/tags")'
fail "$RS" "a dereference is code, not a comment" '    *path = home.join(".acpmux");'
fail "cmux-tui/crates/fix ture/src/lib.rs" "a path with a space" '    home.join(".acpmux")'
pass "$RS" "a baseline without a trailing newline" '    home.join(".acpmux")' "$RS\t1\tkeep\tresolver"
code=0; check "$RS" '    home.join(".acpmux")' "$RS\t1\tkeep\tresolver\n$RS\t1\tkeep\tresolver\n" || code=$?
[[ $code -eq 2 ]] || { echo "FAIL: a duplicate baseline row must exit 2 (got $code)" >&2; exit 1; }
code=0; check "$RS" '    home.join(".acpmux")' "$RS\t1\tmaybe\tcx-test\n" || code=$?
[[ $code -eq 2 ]] || { echo "FAIL: a bad baseline class must exit 2 (got $code)" >&2; exit 1; }
# Test files are not product code.
pass cmux-tui/crates/fixture/tests/it.rs "an integration test" '    home.join(".acpmux")'
pass cmux-tui/crates/fixture/src/server_tests.rs "a Rust unit test file" '    home.join(".acpmux")'
pass Packages/macOS/CmuxNext/Tests/FixtureTests/FixtureTests.swift "a Swift test" '        home + "/.acpmux"'
pass Packages/macOS/OtherPackage/Sources/Other/Other.swift "a package outside the lint's scope" '        home + "/.acpmux"'
# ---- Classic ids and paths (per matched text, classic-ids-baseline.tsv) ----
# Like check/pass/fail, with the classic-ids baseline $3 and an empty state-roots one.
idcheck() {
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/$(dirname "$1")" "$tmp/repo/scripts/cmux-next"
  printf '%s\n' "$2" > "$tmp/repo/$1"
  : > "$tmp/repo/scripts/cmux-next/state-roots-baseline.tsv"
  printf '%b' "${3:-}" > "$tmp/repo/scripts/cmux-next/classic-ids-baseline.tsv"
  local code=0
  bash "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  if [[ $code -eq 1 ]] && ! grep -q "$1" "$tmp/err"; then code=3; fi
  return "$code"
}
idpass() { idcheck "$1" "$3" "${4:-}" || { echo "FAIL: must pass: $2" >&2; cat "$tmp/err" >&2; exit 1; }; }
idfail() {
  local code=0
  idcheck "$1" "$3" "${4:-}" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $2" >&2; cat "$tmp/err" >&2; exit 1; }
}
idcode() { local code=0; idcheck "$1" "$2" "$3" || code=$?; [[ $code -eq $4 ]] || { echo "FAIL: $5 (got $code, want $4)" >&2; cat "$tmp/err" >&2; exit 1; }; }
TS=webviews/src/fixture.ts
PY=scripts/cmux-next/fixture.py
SH=scripts/cmux-next/fixture.sh
CK="Packages/macOS/CmuxNext/Sources/Fixture/Classic.swift"

idfail "$SW" "Classic's config folder" '    let d = home + "/.config/cmux/cmux.json"'
idfail "$SW" "Classic's config folder, closing quote" '    let d = home + "/.config/cmux"'
idfail "$RS" "Classic's state folder" '    let d = home.join(".local/state/cmux/server");'
idfail "$SW" "Classic's caches" '    let d = "\(home)/Library/Caches/cmux/x"'
idfail "$RS" "Classic's XDG cache" '    let d = format!("{home}/.cache/cmux/x");'
idfail "$SW" "Classic's logs" '    let d = "\(home)/Library/Logs/cmux"'
idfail "$SW" "Classic's release socket" '    let s = "/tmp/cmux.sock"'
idfail "$SW" "Classic's channel socket" '    let s = "/tmp/cmux-nightly.sock"'
idfail "$SW" "the bare Classic bundle id" '    let id = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"'
idfail "$SW" "a Classic defaults suite" '    let d = UserDefaults(suiteName: "com.cmuxterm.app")'
idfail "$RS" "a Classic prefs domain in Rust" '    let domain = "com.cmuxterm.app";'
idfail "$SW" "an assembled Classic folder (Swift)" '    let d = home.appendingPathComponent(".config").appendingPathComponent("cmux")'
idfail "$SW" "an assembled Classic folder (appending path:)" '    let d = base.appending(path: "cmux")'
idfail "$RS" "an assembled Classic folder (Rust join)" '    let d = home.join(".config").join("cmux");'
idfail "$PY" "an assembled Classic folder (os.path.join)" '    d = os.path.join(home, ".local", "state", "cmux")'
idfail "$TS" "a path in a web view" '    const d = `${home}/.config/cmux/cmux.json`'
idfail "$SH" "a script" '    d="$HOME/.local/state/cmux/x"'
idfail "$RS" "a text twice in one line" '    let a = "/.config/cmux/a"; let b = "/.config/cmux/b";' "$RS\t.config/cmux\t1\tkeep\treviewed\n"
idpass "$SW" "another id that only starts with the Classic id (com.cmuxterm.appx)" '    let ok = !isCmux("com.cmuxterm.appx")'
idpass "$SW" "a reworded line keeps its row: the id, a quote to a slash" '    let d = "com.cmuxterm.app/x"' "$SW\tcom.cmuxterm.app\t1\tkeep\treviewed\n"
idpass "$SW" "a reworded line keeps its row: the id, a quote to a space" '    let d = "com.cmuxterm.app x"' "$SW\tcom.cmuxterm.app\t1\tkeep\treviewed\n"
idpass "$SW" "a reworded line keeps its row: a root, a slash to a quote" '    let d = home + "/.config/cmux"' "$SW\t.config/cmux\t1\tkeep\treviewed\n"
idpass "$RS" "a reworded line keeps its row: a join, a paren to a comma" '    let d = home.join("cmux", "x");' "$RS\tjoin(\"cmux\")\t1\tkeep\treviewed\n"
idpass "$SW" "NEXT's own config folder" '    let d = home + "/.config/cmux-next/cmux-next.json"'
idpass "$SW" "NEXT's own state folder" '    let d = home + "/.local/state/cmux-next/x"'
idpass "$RS" "NEXT's own cache" '    let d = format!("{home}/.cache/cmux-next/x");'
idpass "$SW" "NEXT's own bundle id" '    let id = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next"'
idpass "$SW" "a NEXT channel bundle id" '    let id = "com.cmuxterm.app.nightly.cmux-next"'
idpass "$SW" "a NEXT socket" '    let s = "/tmp/cmux-next-nightly.sock"'
idpass "$SW" "NEXT's own folder component" '    let d = home.appendingPathComponent("cmux-next")'
idpass "$RS" "another cmux crate folder" '    let d = home.join("cmux-tui");'
idpass "$SW" "a comment" '    // Classic keeps ~/.config/cmux and com.cmuxterm.app here'
idpass "$SW" "a doc comment" '    /// Classic'"'"'s /tmp/cmux.sock'
idpass "$PY" "a Python comment" '# the Classic folder ~/.config/cmux
x = 1'
idpass "$RS" "a Rust attribute is code, not a comment" '#[cfg(test)]'
idpass "$RS" "a baselined text" '    let d = home.join(".local/state/cmux/server");' "$RS\t.local/state/cmux\t1\tkeep\treviewed read\n"
idpass "$SW" "a move row naming lane A" '    let d = "/tmp/cmux.sock"' "$SW\t/tmp/cmux.sock\t1\tmove\tlane A: socket root\n"
idpass "$SW" "a move row naming lane B" '    let d = "com.cmuxterm.app"' "$SW\tcom.cmuxterm.app\t1\tmove\tlane B: defaults read\n"
idpass "$SW" "a baselined text with a changed line number" '
    // padding
    let d = "/tmp/cmux.sock"' "$SW\t/tmp/cmux.sock\t1\tkeep\treviewed\n"
idfail "$SW" "a new Classic text beside a baselined one" '    let a = "/tmp/cmux.sock"
    let b = "/.config/cmux/x"' "$SW\t/tmp/cmux.sock\t1\tkeep\treviewed\n"
idfail "$SW" "a second use of a baselined text" '    let a = "/tmp/cmux.sock"
    let b = "/tmp/cmux.sock"' "$SW\t/tmp/cmux.sock\t1\tkeep\treviewed\n"
idfail "$SW" "a stale row whose text is gone" '    let a = 1' "$SW\t/tmp/cmux.sock\t1\tmove\tlane A: socket root\n"
idfail "$SW" "a row with a lower use count" '    let a = "/tmp/cmux.sock"' "$SW\t/tmp/cmux.sock\t2\tkeep\treviewed\n"
idfail "$SW" "a row for another file" '    let a = "/tmp/cmux.sock"' "Packages/macOS/CmuxNext/Sources/Other/O.swift\t/tmp/cmux.sock\t1\tkeep\treviewed\n"
idcode "$SW" '    let a = "/tmp/cmux.sock"' "$SW\t/tmp/cmux.sock\t1\tmove\tneeds a lane\n" 2 "a move row must name lane A or B"
idcode "$SW" '    let a = "/tmp/cmux.sock"' "$SW\t/tmp/cmux.sock\t1\tmaybe\tlane A\n" 2 "a bad class must exit 2"
idcode "$SW" '    let a = "/tmp/cmux.sock"' "$SW\t/tmp/cmux.sock\t1\tkeep\treviewed\n$SW\t/tmp/cmux.sock\t1\tkeep\treviewed\n" 2 "a duplicate row must exit 2"
idcode "$SW" '    let a = 1' "$SW\t/tmp/cmux.sock\tmany\tkeep\treviewed\n" 2 "a bad count must exit 2"
idpass Packages/macOS/CmuxNext/Tests/FixtureTests/FixtureTests.swift "a Swift test" '    let a = "/tmp/cmux.sock"'
idpass cmux-tui/crates/fixture/src/server_tests.rs "a Rust test file" '    let a = "/.config/cmux/";'
idpass cmux-tui/crates/fixture/tests/it.rs "a Rust integration test" '    let a = "com.cmuxterm.app";'
idpass webviews/src/fixture.test.ts "a web view test" '    const a = "/.config/cmux/";'
idpass webviews/node_modules/pkg/index.js "node_modules" '    const a = "/.config/cmux/";'
idpass scripts/cmux-next/tests/fixture.sh "a script test" '    a=/tmp/cmux.sock'
idpass scripts/ci/fixture.sh "a script outside scripts/cmux-next (Classic's own tooling)" '    a=/tmp/cmux.sock'
idpass Packages/iOS/Fixture/Fixture.swift "a package outside Packages/macOS" '    let a = "com.cmuxterm.app"'
echo "check-state-roots.test: ok"
