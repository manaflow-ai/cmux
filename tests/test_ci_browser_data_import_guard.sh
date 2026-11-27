#!/usr/bin/env bash
# The cx-f58x browser-data notary-test guard must pass a bundle without browser
# targets (cmux's own "cmux Safe Storage" item and prose about a Safe Storage
# are fine, the Chromium engine is skipped) and fail on another browser's
# Safe Storage name or credential file, or on a shipped target list.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECKER="$ROOT_DIR/scripts/ci/check-browser-data-import-absent.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-browser-data-guard.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

app="$tmp/clean.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks/Chromium Embedded Framework.framework" "$app/Contents/Resources"
printf 'cmux Safe Storage\nonly Chromium rows have a Safe Storage\n' > "$app/Contents/MacOS/cmux"
printf 'Login Data\nChrome Safe Storage\n' > "$app/Contents/Frameworks/Chromium Embedded Framework.framework/engine"
printf '{"schemaVersion": 1, "engines": {}, "browsers": []}\n' > "$app/Contents/Resources/browser-sources.json"
if ! "$CHECKER" "$app"; then
  echo "FAIL: a bundle without browser targets must pass" >&2
  exit 1
fi

for case in 'Brave Safe Storage' 'logins.json' 'Network/Cookies' '"dataDirectories": ["Library/Application Support/Google/Chrome"]'; do
  bad="$tmp/bad.app"
  rm -rf "$bad"
  cp -R "$app" "$bad"
  printf '%s\n' "$case" >> "$bad/Contents/MacOS/cmux"
  if "$CHECKER" "$bad" 2>/dev/null; then
    echo "FAIL: '$case' must fail the guard" >&2
    exit 1
  fi
done

echo "PASS: browser-data import guard catches browser targets outside the Chromium engine"
