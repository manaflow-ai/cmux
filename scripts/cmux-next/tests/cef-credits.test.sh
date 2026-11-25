#!/usr/bin/env bash
# Chromium's CREDITS.html in the cmux-next app (license notices for Chromium and
# its third-party components). install-cef-credits.sh puts it in the embedded
# CEF framework's Resources as CREDITS.html.gz (gzip -9 -n): the CEF artifact's
# own CREDITS.html when it has one (the fork's generated file, from cef cmux.18),
# else the INTERIM stock CEF credits checked in for the pinned Chromium version.
# check-cef-credits.sh is the release-bundle gate: an app with CEF and no real
# CREDITS.html.gz fails.
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
[[ ! -e "$TMP/res/CREDITS.html" ]] || fail "a plain CREDITS.html was installed"
gzip -dc "$TMP/res/CREDITS.html.gz" > "$TMP/stock.html" || fail "installed credits do not decompress"
head -c 400 "$TMP/stock.html" | grep -q 'INTERIM' || fail "stock credits are not marked interim"
grep -q 'Chromium software is made available' "$TMP/stock.html" || fail "stock credits content missing"
# Every byte of the stock file is there after the header line.
tail -n +2 "$TMP/stock.html" | cmp -s - <(gunzip -c "$S/chromium-credits/154.0.8037.58.html.gz") || fail "stock credits text changed"
"$S/check-cef-credits.sh" "$TMP/res/CREDITS.html.gz" || fail "check refused the stock credits"

# 2. The artifact's own CREDITS.html (framework Resources or dist root) wins,
# unmarked and byte for byte after decompression; a plain copy already in
# Resources (embed-cef.sh copies the artifact's framework) is removed.
for where in "$FW/Resources" .; do
  new_dist "$TMP/dist2"; new_res
  { printf '<!doctype html><title>Credits</title>Chromium software is made available as source code\n'; head -c 200000 /dev/zero | tr '\0' 'x'; } > "$TMP/dist2/$where/CREDITS.html"
  cp "$TMP/dist2/$where/CREDITS.html" "$TMP/res/CREDITS.html"
  "$S/install-cef-credits.sh" "$TMP/dist2" "$TMP/res" 154.0.8037.58 || fail "fork credits ($where) failed"
  [[ ! -e "$TMP/res/CREDITS.html" ]] || fail "the plain copy ($where) was left in Resources"
  gzip -dc "$TMP/res/CREDITS.html.gz" | cmp -s "$TMP/dist2/$where/CREDITS.html" - || fail "fork credits ($where) were not used as is"
  rm -rf "$TMP/dist2"
done

# 2b. The artifact's Resources is the install target itself (same file): still compressed, not lost.
new_res
{ printf '<!doctype html>Chromium software is made available as source code\n'; head -c 200000 /dev/zero | tr '\0' 'y'; } > "$TMP/res/CREDITS.html"
cp "$TMP/res/CREDITS.html" "$TMP/same.html"
mkdir -p "$TMP/dist4/$FW"; ln -s "$TMP/res" "$TMP/dist4/$FW/Resources"
"$S/install-cef-credits.sh" "$TMP/dist4" "$TMP/res" 154.0.8037.58 || fail "in-place credits failed"
gzip -dc "$TMP/res/CREDITS.html.gz" | cmp -s "$TMP/same.html" - || fail "in-place credits were not kept"

# 2c. Deterministic: the same input gives the same bytes (no name or mtime in the gzip header).
new_dist "$TMP/dist5"; new_res
"$S/install-cef-credits.sh" "$TMP/dist5" "$TMP/res" 154.0.8037.58
cp "$TMP/res/CREDITS.html.gz" "$TMP/first.gz"; sleep 1; new_res
"$S/install-cef-credits.sh" "$TMP/dist5" "$TMP/res" 154.0.8037.58
cmp -s "$TMP/first.gz" "$TMP/res/CREDITS.html.gz" || fail "install is not deterministic"

# 3. No artifact credits and no stock file for this Chromium: fails.
new_dist "$TMP/dist3"; new_res
if "$S/install-cef-credits.sh" "$TMP/dist3" "$TMP/res" 999.0.0.1 2>/dev/null; then fail "unknown Chromium version passed"; fi

# 4. The release gate refuses a missing file, the sample placeholder, a stub and a corrupt gzip.
"$S/check-cef-credits.sh" "$TMP/missing.html" 2>/dev/null && fail "check passed a missing file"
printf '<html><body>This is a sample credits page.</body></html>\n' > "$TMP/sample.html"
"$S/check-cef-credits.sh" "$TMP/sample.html" 2>/dev/null && fail "check passed the sample credits page"
{ cat "$TMP/sample.html"; head -c 200000 /dev/zero | tr '\0' 'z'; } | gzip -9 -n > "$TMP/sample.html.gz"
"$S/check-cef-credits.sh" "$TMP/sample.html.gz" 2>/dev/null && fail "check passed the compressed sample credits page"
printf '<html>Credits</html>\n' > "$TMP/stub.html"
"$S/check-cef-credits.sh" "$TMP/stub.html" 2>/dev/null && fail "check passed a stub"
gzip -9 -n -c "$TMP/stub.html" > "$TMP/stub.html.gz"
"$S/check-cef-credits.sh" "$TMP/stub.html.gz" 2>/dev/null && fail "check passed a compressed stub (it judged the compressed size)"
head -c 300000 /dev/urandom > "$TMP/corrupt.html.gz"
"$S/check-cef-credits.sh" "$TMP/corrupt.html.gz" 2>/dev/null && fail "check passed a corrupt gzip"

# 5. Given an app, the gate reads the framework's CREDITS.html.gz; a plain CREDITS.html alone fails.
APP="$TMP/x.app"; R="$APP/Contents/Frameworks/$FW/Resources"; mkdir -p "$R"
cp "$TMP/stock.html" "$R/CREDITS.html"
"$S/check-cef-credits.sh" "$APP" 2>/dev/null && fail "check passed an app with only a plain CREDITS.html"
gzip -9 -n -c "$TMP/stock.html" > "$R/CREDITS.html.gz"; rm "$R/CREDITS.html"
"$S/check-cef-credits.sh" "$APP" | grep -q 'INTERIM' || fail "check refused the app's CREDITS.html.gz"
printf 'cef-credits tests: ok\n'
