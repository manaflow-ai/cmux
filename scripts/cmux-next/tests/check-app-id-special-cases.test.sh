#!/usr/bin/env bash
# check-app-id-special-cases.py (docs/app-store-platonic-ideal.md 5, phase 0):
# a first-party app id literal in Swift or Rust product code fails unless the
# baseline lists it; op names, comments, tests and first-party-apps/ are out
# of scope; the baseline counts per file and only goes down.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-app-id-special-cases.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-app-ids.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

check() {
  local baseline="$1"
  shift
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/scripts/cmux-next" "$tmp/repo/first-party-apps/home" "$tmp/repo/first-party-apps/app-store"
  printf '%b' "$baseline" > "$tmp/repo/scripts/cmux-next/app-id-special-cases-baseline.tsv"
  local pair
  for pair in "$@"; do
    mkdir -p "$tmp/repo/$(dirname "${pair%%=*}")"
    printf '%s\n' "${pair#*=}" > "$tmp/repo/${pair%%=*}"
  done
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >/dev/null 2>"$tmp/err" || code=$?
  return "$code"
}
SWIFT=Packages/macOS/CmuxNext/Sources/CmuxNextApp/Route.swift
RUST=cmux-tui/crates/cmux-tui-core/src/apps/route.rs
pass() { local what="$1"; shift; check "$@" || { echo "FAIL: must pass: $what" >&2; cat "$tmp/err" >&2; exit 1; }; }
fail() { local what="$1"; shift; if check "$@"; then echo "FAIL: must fail: $what" >&2; exit 1; fi; }

fail "a Swift switch on an app id" "" "$SWIFT=case \"cmux/home\": showHome()"
fail "a Rust comparison with an app id" "" "$RUST=if app == \"cmux/app-store\" { return; }"
fail "the namespace form" "" "$RUST=let ns = \"cmux.home\";"
pass "an op name is not an app id" "" "$SWIFT=run(\"cmux.home.open\")"
pass "a third-party id is not first-party" "" "$SWIFT=let id = \"acme/home\""
pass "comments are out of scope" "" "$SWIFT=// was \"cmux/home\""
pass "tests are out of scope" "" "Packages/macOS/CmuxNext/Tests/X/RouteTests.swift=#expect(id == \"cmux/home\")"
pass "a Rust test module is out of scope" "" "$RUST=fn a() {}
#[cfg(test)]
mod tests { const A: &str = \"cmux/home\"; }"
pass "a baselined site" "$SWIFT\t1\n" "$SWIFT=case \"cmux/home\": showHome()"
fail "one more than the baseline" "$SWIFT\t1\n" "$SWIFT=case \"cmux/home\", \"cmux/app-store\": show()"
pass "fewer than the baseline only notes" "$SWIFT\t3\n" "$SWIFT=case \"cmux/home\": showHome()"
fail "a site moved to another file" "$SWIFT\t1\n" "$RUST=let a = \"cmux/home\";"
echo "check-app-id-special-cases.test.sh: ok"
