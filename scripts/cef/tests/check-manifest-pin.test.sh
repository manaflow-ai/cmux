#!/usr/bin/env bash
# check-manifest-pin.sh: equal pins pass; a different Next pin warns (exit 0)
# or fails with --strict; a missing ref is a skip.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
S="$ROOT/scripts/cef/check-manifest-pin.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cp "$ROOT/scripts/cef/cef-manifest.json" "$TMP/same.json"
out=$(bash "$S" --next-manifest "$TMP/same.json" 2>&1) || fail "equal pins failed: $out"
grep -q 'CEF pins match' <<<"$out" || fail "equal pins not reported: $out"

python3 -I - "$TMP/same.json" "$TMP/bumped.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["version"] = d["version"] + "-next"; d["sha256"] = "0" * 64
json.dump(d, open(sys.argv[2], "w"))
PY
out=$(bash "$S" --next-manifest "$TMP/bumped.json" 2>&1) || fail "a mismatch must only warn without --strict"
grep -q 'warning: the CEF pins differ in version, sha256' <<<"$out" || fail "mismatch not reported: $out"
if bash "$S" --strict --next-manifest "$TMP/bumped.json" >/dev/null 2>&1; then fail "--strict passed a mismatch"; fi

out=$(bash "$S" --ref refs/heads/no-such-branch-for-cef-pin 2>&1) || fail "a missing ref must skip"
grep -q '^skip:' <<<"$out" || fail "missing ref not skipped: $out"
printf 'check-manifest-pin tests: ok\n'
