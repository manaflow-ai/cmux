#!/usr/bin/env bash
# Puts the pinned full uBlock Origin (GPL-3.0) into the app bundle at
# Contents/Resources/Extensions/ublock-origin (run by embed-cef.sh, the Xcode
# "Embed CEF" phase; the app loads it when browser.builtInAdBlocker is on,
# CEFBuiltInExtensions.swift). The copy comes from fetch-ublock.sh (pinned
# release ZIP, SHA-256 checked, cached). It carries LICENSE.txt, SOURCE.txt
# (corresponding source link) and its source receipt.
#
# No network or a failed check leaves a build without it: the app then starts
# Chromium without the built-in blocker. CMUX_NEXT_REQUIRE_UBLOCK=1 turns
# that into a build failure (release builds). CMUX_NEXT_SKIP_UBLOCK=1 skips it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
dest="$app/Contents/Resources/Extensions/ublock-origin"

if [[ "${CMUX_NEXT_SKIP_UBLOCK:-}" == 1 ]]; then
  rm -rf "$dest"
  echo "uBlock Origin: skipped (CMUX_NEXT_SKIP_UBLOCK=1)"
  exit 0
fi
if ! src="$("$script_dir/fetch-ublock.sh")" || [[ ! -f "$src/manifest.json" ]]; then
  rm -rf "$dest"
  if [[ "${CMUX_NEXT_REQUIRE_UBLOCK:-}" == 1 ]]; then
    echo "error: the built-in uBlock Origin could not be staged (scripts/cmux-next/fetch-ublock.sh)" >&2
    exit 1
  fi
  echo "warning: built-in uBlock Origin not bundled (fetch-ublock.sh failed); Chromium starts without it" >&2
  exit 0
fi
mkdir -p "$dest"
/usr/bin/rsync -a --delete "$src/" "$dest/"
# uBlock ships 72 _locales catalogs (3.8 MB); keep the ones CEF keeps for cmux's 21 languages
# (cef-locale-allowlist.sh), so its UI speaks the language Chromium does. Chromium reads the
# browser locale's catalog and falls back to the manifest's default_locale, which is always kept.
# shellcheck source=scripts/cmux-next/cef-locale-allowlist.sh
source "$script_dir/cef-locale-allowlist.sh"
keep="$(cef_locale_allowlist)"
default_locale="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("default_locale", "en"))' "$dest/manifest.json")"
removed=0
for locale_dir in "$dest/_locales"/*/; do
  locale="$(basename "$locale_dir")"
  case $'\n'"$keep"$'\n'"$default_locale"$'\n' in
    *$'\n'"$locale"$'\n'*) ;;
    *) rm -rf "$locale_dir"; removed=$((removed + 1)) ;;
  esac
done
# The URLhaus malware list ("Online Malicious URL Blocklist", urlhaus-1, on by default) is a feed of
# malware URLs online now that expires in 12 hours: 0.8 MB in uBlock 1.75.0, 12.0 MB in 1.76.4 (the
# feed grew). uBlock reads a bundled list only while its cache has no copy (assets.js caches only
# downloads), and the launch that reads it starts the update cycle 2 s later (start.js: a list never
# downloaded counts as overdue), which downloads every list. So the 12 MB snapshot covers only the
# seconds before that download, or a launch with no network, where no web page loads either. Ship the
# list's header only: uBlock still reads it from the package, so filtering starts at once without
# waiting on the network (a missing file would make the first launch wait for the 12 MB download),
# and the update cycle fills it in, as it does for every bundled list.
urlhaus="$dest/assets/thirdparties/urlhaus-filter/urlhaus-filter-online.txt"
urlhaus_note=""
if [[ -f "$urlhaus" ]]; then
  /usr/bin/python3 -I - "$urlhaus" <<'PY'
import sys
path = sys.argv[1]
header = []
with open(path, encoding="utf-8") as f:
    for line in f:
        if not line.startswith("!"):
            break
        header.append(line)
header.append("! cmux: the entries are removed from this bundled copy; uBlock Origin downloads the\n")
header.append("! current list in the update cycle it starts 2 seconds after launch (bundle-ublock.sh).\n")
with open(path, "w", encoding="utf-8") as f:
    f.write("".join(header))
PY
  urlhaus_note=1
fi
# GPL-3.0 section 5(a): a modified copy says what changed and when. The bundled copy's SOURCE.txt
# (fetch-ublock.sh writes it; the cache keeps its own) names every change; each date is the day that
# change to the copy was made, not the build's, so builds stay reproducible.
/usr/bin/python3 -I - "$dest/SOURCE.txt" "$removed" "$urlhaus_note" <<'PY'
import sys
path, removed, urlhaus = sys.argv[1], sys.argv[2], sys.argv[3]
line = ("cmux changes (2026-11-12): the manifest's \"key\" field (keeps the Chrome Web Store extension id),\n"
        f"and the _locales catalogs of the {removed} languages cmux does not ship are removed\n"
        "(scripts/cmux-next/bundle-ublock.sh); the browser falls back to the default locale for them.\n")
if urlhaus:
    line += ("cmux changes (2026-11-18): assets/thirdparties/urlhaus-filter/urlhaus-filter-online.txt keeps\n"
             "its header only (scripts/cmux-next/bundle-ublock.sh); uBlock Origin downloads the current\n"
             "list in the update cycle it starts 2 seconds after launch.\n")
text = open(path).read()
lines = text.splitlines(keepends=True)
for i, l in enumerate(lines):
    if l.startswith("cmux changes"):
        lines[i] = line
        break
else:
    lines.append(line)
open(path, "w").write("".join(lines))
PY
echo "bundled uBlock Origin from $src ($removed locale catalogs removed${urlhaus_note:+, URLhaus list entries removed})"
