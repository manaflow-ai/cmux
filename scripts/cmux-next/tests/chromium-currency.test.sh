#!/usr/bin/env bash
# check-chromium-currency.py: a pin at most one Chrome stable milestone behind
# passes, two or more fails, and a manifest it cannot read is exit 2, never a pass.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/../check-chromium-currency.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-currency.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

printf '{"version":"cef-156.0.14-cmux.1","chromium":"156.0.8078.80","backports":["CVE-2026-106378"]}' > "$work/m156.json"
printf '{"version":"cef-154.0.28-cmux.37","chromium":"154.0.8037.98"}' > "$work/m154.json"

python3 "$check" --manifest "$work/m156.json" --stable 157.0.8103.26 >/dev/null || fail "one behind must pass"
python3 "$check" --manifest "$work/m156.json" --stable 156.0.8078.80 >/dev/null || fail "same milestone must pass"
set +e
python3 "$check" --manifest "$work/m154.json" --stable 157.0.8103.26 >/dev/null 2>&1; code=$?
python3 "$check" --manifest "$work/missing.json" --stable 157.0.8103.26 >/dev/null 2>&1; missing=$?
python3 "$check" --manifest "$work/m154.json" --stable 156.0.8078.80 >/dev/null 2>&1; two=$?
set -e
[ "$code" = 1 ] || fail "three behind must fail (got $code)"
[ "$two" = 1 ] || fail "two behind must fail (got $two)"
[ "$missing" = 2 ] || fail "unreadable manifest must be exit 2 (got $missing)"
echo "chromium-currency: ok"
