#!/usr/bin/env bash
# ratchet-debt-issue.py --dry-run: groups the checks' ratchet debt annotations
# by check, and closes the issue when there is none. Never calls gh.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ratchet-debt.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$tmp/out" >&2; exit 1; }
run() { PATH="$tmp/nogh:$PATH" python3 -I "$ROOT_DIR/scripts/cmux-next/ratchet-debt-issue.py" --repo o/r --sha 0123456789abcdef --run-url https://example.invalid/run --dry-run "$tmp/debt" > "$tmp/out"; }
# A gh that fails, so a call to it fails the test.
mkdir -p "$tmp/nogh" "$tmp/debt"; printf '#!/bin/sh\nexit 99\n' > "$tmp/nogh/gh"; chmod +x "$tmp/nogh/gh"

printf '%s\n' 'god type: type A/B spans 1100 lines' '::warning title=ratchet debt::god type: type A/B spans 1100 lines' > "$tmp/debt/godfiles-swift.log"
printf '%s\n' 'check-scrollbars: ok' > "$tmp/debt/scrollbars.log"
run
grep -q '^open or rewrite' "$tmp/out" || fail "debt must open or rewrite the issue"
grep -q '^1 style ratchet warnings on feat-cmux-next at 0123456789ab' "$tmp/out" || fail "the body must count the debt at the commit"
grep -q '^### God files and types (Swift) (1)' "$tmp/out" || fail "the body must group by check"
grep -q 'Scrollbars' "$tmp/out" && fail "a check without debt must not be listed"

rm "$tmp/debt/godfiles-swift.log"
run
grep -q '^close if open' "$tmp/out" || fail "no debt must close the issue"
echo "ratchet debt issue: ok"
