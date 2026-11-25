#!/usr/bin/env bash
# pin-browser-test-font.sh
#
# Makes the browser lane's engines (Playwright's WebKit, Chrome's headless shell) draw the UI font with one known face
# on Linux: Inter, through a fontconfig alias for every family the UI font stack names (-apple-system,
# BlinkMacSystemFont, system-ui, sans-serif). Run it after the engines are installed and before the webview tests.
#
# Why: the UI font is the macOS system font (--font-ui: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
# ab5bc5a1228, 2026-11-08, Leo's font order). A Linux runner has no SF Pro, so the stack fell to whatever fontconfig
# picks (DejaVu Sans on the runners), and every browser geometry test measured that face: text centers 0.63 px off
# their controls (composer-alignment-centers, composer-plus-geometry), on every feat-cmux-next push since. The tests
# check the layout, so they need a face with stable metrics; the product keeps the system font.
#
# Linux only (the browser lane runs nowhere else). Exits 1 when the alias does not take, so the tests never measure
# a fallback face again unseen.
set -euo pipefail

[ "$(uname -s)" = Linux ] || { echo "pin-browser-test-font: not Linux, nothing to pin"; exit 0; }

# The distribution's Inter (TTF/OTF): the engines' own FreeType reads no WOFF2, so the repository's chat-font subset
# matched in fc-match but never drew (the first try left every center 0.63 px off).
if ! fc-list : family | grep -qx 'Inter'; then
  sudo apt-get install -y --no-install-recommends fonts-inter > /dev/null
fi
family=Inter
fc-list : family | grep -qx "$family" || { echo "::error::pin-browser-test-font: fonts-inter gave no $family face" >&2; exit 1; }
conf="${XDG_CONFIG_HOME:-$HOME/.config}/fontconfig/conf.d"
mkdir -p "$conf"

cat > "$conf/99-cmux-browser-test-font.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- Written by scripts/ci/pin-browser-test-font.sh: the browser tests' UI face. -->
<fontconfig>
  <alias binding="strong"><family>-apple-system</family><prefer><family>$family</family></prefer></alias>
  <alias binding="strong"><family>BlinkMacSystemFont</family><prefer><family>$family</family></prefer></alias>
  <alias binding="strong"><family>system-ui</family><prefer><family>$family</family></prefer></alias>
  <alias binding="strong"><family>sans-serif</family><prefer><family>$family</family></prefer></alias>
</fontconfig>
EOF
fc-cache -f > /dev/null

for generic in -apple-system BlinkMacSystemFont system-ui sans-serif; do
  got="$(fc-match --format '%{family[0]}' -- "$generic")"
  if [ "$got" != "$family" ]; then
    echo "::error::pin-browser-test-font: $generic resolves to $got, not $family" >&2
    exit 1
  fi
done
echo "pin-browser-test-font: the UI font stack draws $(fc-match --format '%{file}' -- system-ui)"
