#!/usr/bin/env bash
# ensure-system-chrome.sh [--optional]
#
# Makes sure the system Google Chrome (Playwright's channel "chrome") is installed and has the
# fixes for CVE-2026-118306, -118331, -118348 and -118344 (Chrome 156.0.8078.73 or later).
# Tests launch it instead of Playwright's bundled Chromium, which every Playwright release up to
# 1.64.1 ships older than that, unsandboxed (webviews/test/support/systemChrome.ts).
#
# Linux CI: installs or updates Chrome stable with `playwright install --with-deps chrome` (run
# from a folder with Playwright in node_modules, or with bunx/npx on PATH). macOS (GitHub Actions
# runners only, see below): uses /Applications/Google Chrome.app, installed by Playwright where sudo
# needs no password.
# --optional: where Chrome is missing or old and cannot be installed, warn and exit 0 (a fleet
# step's browser lane then skips Chromium, as it skips any engine that cannot launch).
#
# Headless launches use Chrome for Testing's chrome-headless-shell at the current stable version
# (the engine Playwright's own headless launches use, so tests keep its rendering and timing; full
# Chrome's new headless mode fails timing-sensitive tests, run 41567413265). It is fetched into
# $CMUX_CI_CACHE_DIR (or ~/.cache/cmux-ci), needs no install rights, and its path is written as
# CMUX_CHROME_HEADLESS_SHELL to $GITHUB_ENV when set and printed as the last line
# (`CMUX_CHROME_HEADLESS_SHELL=<path>`), which test/support/systemChrome.ts reads.
set -euo pipefail

min="156.0.8078.73"
optional=0
[ "${1:-}" = --optional ] && optional=1

# No Playwright on Macs (Lawrence, 2026-11-02): no Playwright, Puppeteer or downloaded Chromium on his
# Mac or a fleet Mac, and Playwright turns the Chromium sandbox off whatever Chrome it drives. So on
# a Mac outside GitHub Actions this never copies Chrome into /Applications, never installs it
# through Playwright, and never vouches for a Chrome for Playwright to drive. --optional still exits
# 0 there, and the Chromium cases skip (the webviews browser files skip on a Mac anyway).
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "$(uname -s)" = Darwin ]; then
  echo "ensure-system-chrome.sh: not on a Mac (Lawrence's rule: no Playwright on Macs); run it in CI or on a cloud VM" >&2
  exit $((1 - optional))
fi

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


# chrome-headless-shell from Chrome for Testing, at stable (>= $min). Best effort: prints nothing
# when it cannot be fetched, and launches then fall back to channel "chrome".
ensure_headless_shell() {
  local platform json version url cache dir bin
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=mac-arm64 ;;
    Darwin-x86_64) platform=mac-x64 ;;
    Linux-x86_64) platform=linux64 ;;
    Linux-aarch64) platform=linux-arm64 ;;
    *) return 0 ;;
  esac
  cache="${CMUX_CI_CACHE_DIR:-$HOME/.cache/cmux-ci}"
  # A cached shell new enough is used without asking the network.
  local candidates
  candidates="$(printf '%s\n' "$cache"/chrome-headless-shell-* | sort -V -r)"
  for dir in $candidates; do
    version="${dir##*/chrome-headless-shell-}"
    bin="$dir/chrome-headless-shell-$platform/chrome-headless-shell"
    if at_least "$version" "$min" && [ -x "$bin" ]; then
      echo "$bin"
      return 0
    fi
  done
  json="$(curl -fsS --retry 3 -m 30 https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json)" || return 0
  read -r version url < <(printf '%s' "$json" | python3 -c '
import json, sys
stable = json.load(sys.stdin)["channels"]["Stable"]
urls = {d["platform"]: d["url"] for d in stable["downloads"].get("chrome-headless-shell", [])}
print(stable["version"], urls.get(sys.argv[1], ""))' "$platform") || return 0
  at_least "$version" "$min" && [ -n "$url" ] || return 0
  dir="$cache/chrome-headless-shell-$version"
  mkdir -p "$cache"
  local tmp
  tmp="$(mktemp -d "$cache/.chs.XXXXXX")"
  if curl -fsSL --retry 3 -m 900 -o "$tmp/shell.zip" "$url" && (cd "$tmp" && unzip -q shell.zip) &&
    [ -x "$tmp/chrome-headless-shell-$platform/chrome-headless-shell" ]; then
    rm -f "$tmp/shell.zip"
    rm -rf "$dir"
    mv "$tmp" "$dir"
    echo "$dir/chrome-headless-shell-$platform/chrome-headless-shell"
  else
    rm -rf "$tmp"
  fi
}

ensure_chrome() {
  have="$(chrome_version || true)"
  if at_least "$have" "$min"; then
    echo "system Chrome $have at $(chrome_bin)"
    return 0
  fi

  can_install=0
  if [ "$(uname -s)" = Linux ] || sudo -n true 2> /dev/null; then can_install=1; fi
  if [ "$can_install" = 1 ]; then
    echo "system Chrome ${have:-missing}; installing Chrome stable (need $min or later)"
    # CI=1: reinstall over an older system Chrome instead of stopping at Playwright's prompt.
    # The install runs apt-get update, which fails on a hash mismatch when Google republishes its
    # apt repository mid-fetch (job 127181004735: "Some index files failed to download"); one
    # more try a little later reads the new index.
    local log attempt
    log="$(mktemp)"
    for attempt in 1 2; do
      # shellcheck disable=SC2046
      if CI=1 $(playwright_cli) install --with-deps chrome 2>&1 | tee "$log"; then break; fi
      if [ "$attempt" = 1 ] && grep -qE 'Hash Sum mismatch|Hashes of received file|index files failed to download' "$log"; then
        echo "warning: apt index changed during the fetch; trying once more in 15 s" >&2
        sleep 15
        continue
      fi
      echo "warning: Chrome stable install failed" >&2
      break
    done
    rm -f "$log"
    have="$(chrome_version || true)"
    if at_least "$have" "$min"; then
      echo "system Chrome $have at $(chrome_bin)"
      return 0
    fi
  fi

  msg="system Chrome ${have:-missing} at $(chrome_bin); need $min or later (CVE-2026-118306)"
  if [ "$optional" = 1 ]; then
    echo "warning: $msg; headed Chromium cases skip here" >&2
    return 0
  fi
  echo "error: $msg" >&2
  return 1
}

status=0
ensure_chrome || status=$?
shell_bin="$(ensure_headless_shell || true)"
if [ -n "$shell_bin" ]; then
  echo "chrome-headless-shell $("$shell_bin" --version 2> /dev/null | grep -oE '[0-9.]+$' || echo '?') at $shell_bin"
  [ -n "${GITHUB_ENV:-}" ] && echo "CMUX_CHROME_HEADLESS_SHELL=$shell_bin" >> "$GITHUB_ENV"
  echo "CMUX_CHROME_HEADLESS_SHELL=$shell_bin"
fi
exit "$status"
