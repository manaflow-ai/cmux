#!/usr/bin/env bash
# publish-cef-r2.sh --manifest writes the R2 fields of BOTH artifacts: the
# top-level (arm64) one and the "x86_64" object, also when a field is
# missing (a new pin), and refuses a manifest sha256 that was not published.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
writer="$here/../cef_manifest_r2.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/cef-manifest-r2.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$work/m.json" <<'JSON'
{
  "version": "v",
  "asset": "a-arm64.tar.xz",
  "sha256": "aaaa",
  "debug_asset": "a-arm64-debug.tar.xz",
  "debug_sha256": "bbbb",
  "fork_ref": "f",
  "x86_64": {
    "asset": "a-x86_64.tar.xz",
    "sha256": "cccc",
    "url": "u",
    "debug_asset": "a-x86_64-debug.tar.xz",
    "debug_sha256": "dddd",
    "fork_ref": "f"
  }
}
JSON
printf '%s\n' \
  "a-arm64.tar.xz aaaa cef/aaaa/a-arm64.tar.xz" \
  "a-arm64-debug.tar.xz bbbb cef/bbbb/a-arm64-debug.tar.xz" \
  "a-x86_64.tar.xz cccc cef/cccc/a-x86_64.tar.xz" \
  "a-x86_64-debug.tar.xz dddd cef/dddd/a-x86_64-debug.tar.xz" > "$work/keys"

/usr/bin/python3 "$writer" "$work/m.json" cmux-cef < "$work/keys" 2>/dev/null || fail "writer failed"
/usr/bin/python3 - "$work/m.json" <<'PY' || fail "fields"
import json, sys
m = json.load(open(sys.argv[1]))
x = m["x86_64"]
assert m["r2_bucket"] == "cmux-cef", m
assert m["r2_key"] == "cef/aaaa/a-arm64.tar.xz", m
assert m["debug_r2_key"] == "cef/bbbb/a-arm64-debug.tar.xz", m
assert x["r2_key"] == "cef/cccc/a-x86_64.tar.xz", x
assert x["debug_r2_key"] == "cef/dddd/a-x86_64-debug.tar.xz", x
keys = list(x)
assert keys.index("r2_key") == keys.index("sha256") + 1, keys
PY

# A manifest sha256 that was not published is refused.
sed 's/"cccc"/"eeee"/' "$work/m.json" > "$work/bad.json"
if /usr/bin/python3 "$writer" "$work/bad.json" cmux-cef < "$work/keys" 2>/dev/null; then
  fail "an unpublished x86_64 sha256 was accepted"
fi
echo "cef-manifest-r2: ok"
