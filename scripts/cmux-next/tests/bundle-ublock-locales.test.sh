#!/usr/bin/env bash
# bundle-ublock.sh keeps uBlock's _locales catalogs for the languages CEF keeps
# (cef-locale-allowlist.sh) plus the manifest's default_locale, removes the rest,
# and writes the GPL modification notice. fetch-ublock.sh is stubbed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts" "$tmp/src" "$tmp/build/cmux.app/Contents/Resources"
cp "$here/bundle-ublock.sh" "$here/cef-locale-allowlist.sh" "$tmp/scripts/"
printf '#!/usr/bin/env bash\necho %q\n' "$tmp/src" > "$tmp/scripts/fetch-ublock.sh"
chmod +x "$tmp/scripts/"*.sh
echo '{"name": "uBlock Origin", "default_locale": "en"}' > "$tmp/src/manifest.json"
printf '%s\n' "uBlock Origin 1.0 (https://github.com/gorhill/uBlock), GPL-3.0." \
  "cmux changes: the manifest's \"key\" field only (keeps the Chrome Web Store extension id)." \
  "Bundled libraries keep their own licenses." > "$tmp/src/SOURCE.txt"
for locale in en en_GB de pt_BR zh_TW fi he eo no; do
  mkdir -p "$tmp/src/_locales/$locale"
  echo '{}' > "$tmp/src/_locales/$locale/messages.json"
done

out="$(TARGET_BUILD_DIR="$tmp/build" WRAPPER_NAME=cmux.app "$tmp/scripts/bundle-ublock.sh")"
dest="$tmp/build/cmux.app/Contents/Resources/Extensions/ublock-origin"
kept="$(cd "$dest/_locales" && ls | tr '\n' ' ')"
[[ "$kept" == "de en en_GB pt_BR zh_TW " ]] || { echo "FAIL: kept $kept" >&2; exit 1; }
[[ "$out" == *"(4 locale catalogs removed)"* ]] || { echo "FAIL: output $out" >&2; exit 1; }
grep -q "^cmux changes (2026-11-12): the manifest's \"key\" field" "$dest/SOURCE.txt" || { echo "FAIL: SOURCE.txt names no dated change" >&2; exit 1; }
grep -q "catalogs of the 4 languages cmux does not ship are removed" "$dest/SOURCE.txt" || { echo "FAIL: SOURCE.txt does not name the locale removal" >&2; exit 1; }
! grep -q "field only" "$dest/SOURCE.txt" || { echo "FAIL: SOURCE.txt still says the key is the only change" >&2; exit 1; }
grep -q "Bundled libraries keep their own licenses." "$dest/SOURCE.txt" || { echo "FAIL: the rest of SOURCE.txt was lost" >&2; exit 1; }
[[ ! -e "$dest/CMUX-MODIFICATIONS.txt" ]] || { echo "FAIL: a second notice file" >&2; exit 1; }
grep -q "field only" "$tmp/src/SOURCE.txt" || { echo "FAIL: the cached SOURCE.txt was modified" >&2; exit 1; }
[[ -f "$tmp/src/_locales/fi/messages.json" ]] || { echo "FAIL: the cached source copy was modified" >&2; exit 1; }
echo "ok bundle-ublock keeps the CEF languages and the default locale"
