#!/usr/bin/env bash
# check-visible-only.py (lists draw only visible rows): each visible-only-* ast-grep rule matches its eager-list
# shape and leaves the windowed or fixed forms alone; `// visible-only: <reason>` escapes a hit; tests are out of
# scope; the baseline counts per file and rule, and a lower count asks for the row to be lowered.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-visible-only.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-visible-only.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the check on a repo root whose sources are the "path=content" pairs after the first argument, the baseline
# (may be empty). The rules are this checkout's (the fixture repo has no scripts/cmux-next/lint).
check() {
  local baseline="$1"
  shift
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/scripts/cmux-next"
  printf '%b' "$baseline" > "$tmp/repo/scripts/cmux-next/visible-only-baseline.tsv"
  local pair
  for pair in "$@"; do
    mkdir -p "$tmp/repo/$(dirname "${pair%%=*}")"
    printf '%b\n' "${pair#*=}" > "$tmp/repo/${pair%%=*}"
  done
  local code=0
  python3 -I "$CHECK" "$tmp/repo" >"$tmp/out" 2>"$tmp/err" || code=$?
  return "$code"
}
pass() {
  local what="$1"
  shift
  check "$@" || { echo "FAIL: must pass: $what" >&2; cat "$tmp/err" >&2; exit 1; }
  if grep -q "has [0-9]* \[" "$tmp/err"; then echo "FAIL: must pass with no finding: $what" >&2; cat "$tmp/err" >&2; exit 1; fi
}
fail() {
  local what="$1" rule="$2"
  shift 2
  local code=0
  check "$@" || code=$?
  [[ $code -eq 1 ]] || { echo "FAIL: must fail with a finding (got $code): $what" >&2; cat "$tmp/err" >&2; exit 1; }
  grep -q "\[$rule\]" "$tmp/err" || { echo "FAIL: $what: no [$rule] finding" >&2; cat "$tmp/err" >&2; exit 1; }
  grep -q "realizeVisibleRows" "$tmp/err" || { echo "FAIL: $what: the finding does not say how to fix it" >&2; exit 1; }
}

MAC=Packages/macOS/CmuxNext/Sources/CmuxNextFixture/Fixture.swift
IOS=cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileFixture/Fixture.swift
SHARED=Packages/Shared/CmuxFixture/Sources/CmuxFixture/Fixture.swift
IOSPKG=Packages/iOS/CmuxFixture/Sources/CmuxFixture/Fixture.swift
view() { printf 'struct V: View {\n  var body: some View {\n%s\n  }\n}' "$1"; }
func() { printf 'func f() {\n%s\n}' "$1"; }

# visible-only-eager-stack-in-scroll
fail "ForEach in a VStack in a ScrollView" visible-only-eager-stack-in-scroll \
  "" "$MAC=$(view 'ScrollView { VStack { ForEach(rows) { r in Text(r.name) } } }')"
fail "ForEach in an HStack in a horizontal ScrollView" visible-only-eager-stack-in-scroll \
  "" "$IOS=$(view 'ScrollView(.horizontal) { HStack(spacing: 8) { ForEach(items) { i in Thumb(i) } } }')"
fail "Packages/Shared is in scope" visible-only-eager-stack-in-scroll \
  "" "$SHARED=$(view 'ScrollView { VStack { ForEach(rows) { r in Text(r.name) } } }')"
fail "Packages/iOS is in scope" visible-only-eager-stack-in-scroll \
  "" "$IOSPKG=$(view 'ScrollView { VStack { ForEach(rows) { r in Text(r.name) } } }')"
pass "a LazyVStack" "" "$MAC=$(view 'ScrollView { LazyVStack { ForEach(rows) { r in Text(r.name) } } }')"
pass "a row's own VStack inside a LazyVStack" "" \
  "$MAC=$(view 'ScrollView { LazyVStack { ForEach(rows) { r in VStack { ForEach(r.parts) { p in Text(p) } } } } }')"
pass "a VStack with no ScrollView" "" "$MAC=$(view 'VStack { ForEach(rows) { r in Text(r.name) } }')"
pass "a literal range" "" "$MAC=$(view 'ScrollView { VStack { ForEach(0..<3) { i in Text(label) } } }')"
pass "an enum's cases" "" "$MAC=$(view 'ScrollView { VStack { ForEach(Kind.allCases) { k in Text(k.title) } } }')"
pass "a capped list" "" "$MAC=$(view 'ScrollView { VStack { ForEach(rows.prefix(Self.maxRows)) { r in Text(r.name) } } }')"

# visible-only-foreach-unstable-id
fail "id: \\.offset" visible-only-foreach-unstable-id \
  "" "$IOS=$(view 'VStack { ForEach(Array(rows.enumerated()), id: \\.offset) { _, r in Text(r) } }')"
fail "id: \\.self over a data array" visible-only-foreach-unstable-id \
  "" "$IOS=$(view 'VStack { ForEach(names, id: \\.self) { n in Text(n) } }')"
pass "id: \\.self over a literal range" "" "$IOS=$(view 'VStack { ForEach(0..<3, id: \\.self) { i in Text(label) } }')"
pass "id: \\.self over allCases" "" "$IOS=$(view 'VStack { ForEach(Kind.allCases, id: \\.self) { k in Text(k.title) } }')"
pass "id: \\.self over an array literal" "" "$IOS=$(view 'VStack { ForEach([Kind.a, .b], id: \\.self) { k in Text(k.title) } }')"
pass "id: \\.self in a Picker" "" "$IOS=$(view 'Picker(title, selection: $s) { ForEach(names, id: \\.self) { Text($0) } }')"
pass "a stable id" "" "$IOS=$(view 'VStack { ForEach(rows, id: \\.id) { r in Text(r.name) } }')"

# visible-only-subviews-teardown
fail "subviews.forEach removeFromSuperview" visible-only-subviews-teardown \
  "" "$MAC=$(func '    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }')"
fail "for v in subviews removeFromSuperview" visible-only-subviews-teardown \
  "" "$MAC=$(func '    for v in content.subviews { v.removeFromSuperview() }')"
pass "a for loop with a where clause (removes some)" "" \
  "$MAC=$(func '    for v in content.subviews where !kept.contains(v) { v.removeFromSuperview() }')"
pass "one view removed" "" "$MAC=$(func '    oldRow.removeFromSuperview()')"

# visible-only-stack-set-views
fail "setViews with a mapped array" visible-only-stack-set-views \
  "" "$MAC=$(func '    list.setViews(items.map { Row($0) }, in: .top)')"
fail "setViews with a computed array" visible-only-stack-set-views "" "$MAC=$(func '    list.setViews(rows, in: .top)')"
pass "setViews with an array literal" "" "$MAC=$(func '    row.setViews([icon, label], in: .leading)')"

# visible-only-reload-data
fail "reloadData()" visible-only-reload-data "" "$MAC=$(func '    table.reloadData()')"
pass "a targeted reload" "" "$MAC=$(func '    table.reloadData(forRowIndexes: rows, columnIndexes: [0])')"
pass "Quick Look's panel" "" "$MAC=$(func '    panel.reloadData()')"

# visible-only-sidebar-region-unwindowed
fail "a SidebarRegionView that never gets an itemWindow" visible-only-sidebar-region-unwindowed \
  "" "$MAC=$(func '    let region = SidebarRegionView(region: .top)')"
pass "a SidebarRegionView whose itemWindow is set" "" \
  "$MAC=$(func '    let region = SidebarRegionView(region: .top)\n    region.itemWindow = { self.visibleRect }')"

# Escapes and scope
pass "an escape on the line" "" "$MAC=$(func '    table.reloadData() // visible-only: one row, the header')"
pass "an escape in the comment above" "" "$MAC=$(func '    // visible-only: reloads only when the row count changed\n    table.reloadData()')"
pass "a test file" "" "Packages/macOS/CmuxNext/Tests/CmuxNextFixtureTests/FixtureTests.swift=$(func '    table.reloadData()')"
pass "a vendored file" "" "Packages/Shared/CmuxFixture/Sources/CmuxFixture/Vendor/Lib.swift=$(func '    table.reloadData()')"
pass "a comment" "" "$MAC=$(func '    // table.reloadData() was the old way')"

# The ratchet: counts per file and rule
pass "a baselined hit" "$MAC\tvisible-only-reload-data\t1\n" "$MAC=$(func '    table.reloadData()')"
fail "one more hit than the row" visible-only-reload-data \
  "$MAC\tvisible-only-reload-data\t1\n" "$MAC=$(func '    table.reloadData()\n    other.reloadData()')"
fail "a row of another rule does not cover it" visible-only-reload-data \
  "$MAC\tvisible-only-subviews-teardown\t1\n" "$MAC=$(func '    table.reloadData()')"
code=0
check "$MAC\tvisible-only-reload-data\t2\n" "$MAC=$(func '    table.reloadData()')" || code=$?
[[ $code -eq 1 ]] || { echo "FAIL: fewer hits than the row must fail until it is lowered (got $code)" >&2; exit 1; }
grep -q "lower the baseline, its row in scripts/cmux-next/visible-only-baseline.tsv to 1" "$tmp/err" \
  || { echo "FAIL: fewer hits than the row must ask to lower it" >&2; cat "$tmp/err" >&2; exit 1; }
code=0
check "$MAC\tno-try-bang\t1\n" "$MAC=$(func '    table.reloadData()')" || code=$?
[[ $code -eq 2 ]] || { echo "FAIL: a row of another rule family is a bad row (got $code)" >&2; exit 1; }

echo "check-visible-only: all rule tests passed"
