#!/usr/bin/env bash
# Chromium's CREDITS.html in the cmux-next app (license notices for Chromium and
# its third-party components). install-cef-credits.sh puts it in the embedded
# CEF framework's Resources: the CEF artifact's own CREDITS.html when it has one
# (the fork's generated file, from cef cmux.18), else the INTERIM stock CEF
# credits checked in for the pinned Chromium version. check-cef-credits.sh is the
# release-bundle gate: an app with CEF and no real CREDITS.html fails.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
S="$ROOT/scripts/cmux-next"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FW="Chromium Embedded Framework.framework"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

new_dist() { # <dir>: a CEF artifact without CREDITS.html
  mkdir -p "$1/$FW/Resources"
}
new_res() { rm -rf "$TMP/res"; mkdir -p "$TMP/res"; }

# 1. No CREDITS.html in the artifact: the stock file for the pinned Chromium, marked interim.
new_dist "$TMP/dist1"; new_res
"$S/install-cef-credits.sh" "$TMP/dist1" "$TMP/res" 154.0.8037.58 || fail "stock fallback failed"
head -c 400 "$TMP/res/CREDITS.html" | grep -q 'INTERIM' || fail "stock credits are not marked interim"
grep -q 'Chromium software is made available' "$TMP/res/CREDITS.html" || fail "stock credits content missing"
"$S/check-cef-credits.sh" "$TMP/res/CREDITS.html" || fail "check refused the stock credits"

# 2. The artifact's own CREDITS.html (framework Resources or dist root) wins, unmarked.
for where in "$FW/Resources" .; do
  new_dist "$TMP/dist2"; new_res
  { printf '<!doctype html><title>Credits</title>Chromium software is made available as source code\n'; head -c 200000 /dev/zero | tr '\0' 'x'; } > "$TMP/dist2/$where/CREDITS.html"
  "$S/install-cef-credits.sh" "$TMP/dist2" "$TMP/res" 154.0.8037.58 || fail "fork credits ($where) failed"
  cmp -s "$TMP/dist2/$where/CREDITS.html" "$TMP/res/CREDITS.html" || fail "fork credits ($where) were not used as is"
  rm -rf "$TMP/dist2"
done

# 3. No artifact credits and no stock file for this Chromium: fails.
new_dist "$TMP/dist3"; new_res
if "$S/install-cef-credits.sh" "$TMP/dist3" "$TMP/res" 999.0.0.1 2>/dev/null; then fail "unknown Chromium version passed"; fi

# 4. The release gate refuses a missing file, the sample placeholder and a stub.
"$S/check-cef-credits.sh" "$TMP/missing.html" 2>/dev/null && fail "check passed a missing file"
printf '<html><body>This is a sample credits page.</body></html>\n' > "$TMP/sample.html"
"$S/check-cef-credits.sh" "$TMP/sample.html" 2>/dev/null && fail "check passed the sample credits page"
printf '<html>Credits</html>\n' > "$TMP/stub.html"
"$S/check-cef-credits.sh" "$TMP/stub.html" 2>/dev/null && fail "check passed a stub"
printf 'cef-credits tests: ok\n'
