#!/usr/bin/env bash
# ensure-system-chrome.sh [--optional]
#
# Makes sure the system Google Chrome (Playwright's channel "chrome") is installed and has the
# fixes for CVE-2026-118306, -118331, -118348 and -118344 (Chrome 156.0.8078.73 or later).
# Tests launch it instead of Playwright's bundled Chromium, which every Playwright release up to
# 1.64.1 ships older than that, unsandboxed (webviews/test/support/systemChrome.ts).
#
# Linux CI: installs or updates Chrome stable with `playwright install --with-deps chrome` (run
# from a folder with Playwright in node_modules, or with bunx/npx on PATH). macOS: uses
# /Applications/Google Chrome.app, copied from Google's signed image where /Applications is
# writable (admin users) or installed by Playwright where sudo needs no password.
# --optional: where Chrome is missing or old and cannot be installed, warn and exit 0 (a fleet
# step's browser lane then skips Chromium, as it skips any engine that cannot launch).
set -euo pipefail

min="156.0.8078.73"
optional=0
[ "${1:-}" = --optional ] && optional=1

chrome_bin() {
  case "$(uname -s)" in
    Darwin) echo "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ;;
    *) command -v google-chrome-stable || command -v google-chrome || echo /opt/google/chrome/chrome ;;
  esac
}

chrome_version() {
  local bin
  bin="$(chrome_bin)"
  [ -x "$bin" ] || return 0
  "$bin" --version 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

at_least() { # at_least HAVE WANT
  [ -n "$1" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

playwright_cli() {
  if [ -x ./node_modules/.bin/playwright ]; then
    echo ./node_modules/.bin/playwright
  elif command -v bunx > /dev/null; then
    echo "bunx playwright"
  else
    echo "npx --yes playwright"
  fi
}

have="$(chrome_version || true)"
if at_least "$have" "$min"; then
  echo "system Chrome $have at $(chrome_bin)"
  exit 0
fi

# macOS without sudo: an admin user can write /Applications, so copy Chrome stable from Google's
# signed disk image there (Chrome then keeps itself updated).
install_mac_dmg() {
  local tmp mnt
  tmp="$(mktemp -d)"
  mnt="$tmp/mnt"
  curl -fsSL --retry 3 -o "$tmp/googlechrome.dmg" \
    https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$tmp/googlechrome.dmg"
  if codesign --verify --deep "$mnt/Google Chrome.app" &&
    codesign -dv "$mnt/Google Chrome.app" 2>&1 | grep -q 'TeamIdentifier=EQHXZ8M8AV'; then
    rm -rf "/Applications/Google Chrome.app"
    ditto "$mnt/Google Chrome.app" "/Applications/Google Chrome.app"
  else
    echo "error: downloaded Chrome failed its Google signature check" >&2
  fi
  hdiutil detach -quiet "$mnt" || true
  rm -rf "$tmp"
}

if [ "$(uname -s)" = Darwin ] && ! sudo -n true 2> /dev/null && [ -w /Applications ]; then
  echo "system Chrome ${have:-missing}; copying Chrome stable into /Applications (need $min or later)"
  install_mac_dmg || true
  have="$(chrome_version || true)"
  if at_least "$have" "$min"; then
    echo "system Chrome $have at $(chrome_bin)"
    exit 0
  fi
fi

can_install=0
if [ "$(uname -s)" = Linux ] || sudo -n true 2> /dev/null; then can_install=1; fi
if [ "$can_install" = 1 ]; then
  echo "system Chrome ${have:-missing}; installing Chrome stable (need $min or later)"
  # CI=1: reinstall over an older system Chrome instead of stopping at Playwright's prompt.
  # shellcheck disable=SC2046
  CI=1 $(playwright_cli) install --with-deps chrome || echo "warning: Chrome stable install failed" >&2
  have="$(chrome_version || true)"
  if at_least "$have" "$min"; then
    echo "system Chrome $have at $(chrome_bin)"
    exit 0
  fi
fi

msg="system Chrome ${have:-missing} at $(chrome_bin); need $min or later (CVE-2026-118306)"
if [ "$optional" = 1 ]; then
  echo "warning: $msg; Chromium cases skip here" >&2
  exit 0
fi
echo "error: $msg" >&2
exit 1
