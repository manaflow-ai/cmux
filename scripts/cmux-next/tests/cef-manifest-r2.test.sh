#!/usr/bin/env bash
# publish-cef-r2.sh --manifest writes the R2 fields of BOTH artifacts: the
# top-level (arm64) one and the "x86_64" object, also when a field is
# missing (a new pin), and refuses a manifest sha256 that was not published.
# It updates ONLY the artifacts of the tag it uploads: an artifact whose asset
# was not published in this run (another tag) keeps its fields unchanged.
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
# Publishing another tag (cmux.18) leaves a manifest that still pins cmux.17
# byte-identical and succeeds (it failed on the cmux.17 entries before).
cp "$work/m.json" "$work/old.json"
printf '%s\n' \
  "b-arm64.tar.xz 1111 cef/1111/b-arm64.tar.xz" \
  "b-x86_64.tar.xz 2222 cef/2222/b-x86_64.tar.xz" > "$work/keys-other-tag"
/usr/bin/python3 "$writer" "$work/m.json" cmux-cef < "$work/keys-other-tag" 2>/dev/null \
  || fail "publishing another tag failed on this manifest's entries"
cmp -s "$work/m.json" "$work/old.json" || fail "publishing another tag changed this manifest"

# A manifest whose arm64 entry moved to the new tag while x86_64 still pins the
# old one: only the arm64 fields change; x86_64 keeps its r2_key and debug_r2_key.
/usr/bin/python3 - "$work/m.json" "$work/mixed.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["asset"], m["sha256"] = "b-arm64.tar.xz", "1111"
m["debug_asset"], m["debug_sha256"] = "b-arm64-debug.tar.xz", "3333"
json.dump(m, open(sys.argv[2], "w"), indent=2)
PY
/usr/bin/python3 "$writer" "$work/mixed.json" cmux-cef < "$work/keys-other-tag" 2>/dev/null \
  || fail "a mixed manifest failed"
/usr/bin/python3 - "$work/mixed.json" <<'PY' || fail "mixed fields"
import json, sys
m = json.load(open(sys.argv[1]))
x = m["x86_64"]
assert m["r2_key"] == "cef/1111/b-arm64.tar.xz", m
# The old debug key named another asset; it must not survive.
assert "debug_r2_key" not in m, m
assert x["r2_key"] == "cef/cccc/a-x86_64.tar.xz", x
assert x["debug_r2_key"] == "cef/dddd/a-x86_64-debug.tar.xz", x
PY

echo "cef-manifest-r2: ok"
