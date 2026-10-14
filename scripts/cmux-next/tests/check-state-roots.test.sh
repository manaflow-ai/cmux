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
echo "check-state-roots.test: ok"
