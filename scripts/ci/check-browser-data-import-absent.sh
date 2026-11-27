#!/usr/bin/env bash
# Verify that a Release app built for the cx-f58x browser-data notary test
# (CMUX_NO_BROWSER_DATA_IMPORT, empty browser-sources.json) ships no browser
# target list: no other browser's Safe Storage Keychain names and no browser
# credential, cookie or history file names. The Chromium Embedded Framework
# is skipped: it is Chromium itself, carries its own profile file names, and
# shipped unchanged in the last accepted nightly-next build.
set -euo pipefail

app="${1:?usage: $0 /path/to/cmux.app}"
if [ ! -d "$app/Contents" ]; then
  echo "FAIL: not an app bundle: $app" >&2
  exit 1
fi

# cmux's own "cmux Safe Storage" Keychain item is allowed.
pattern='([A-Z][A-Za-z0-9]*( [A-Z][A-Za-z0-9]*)* Safe Storage)|Login Data|logins\.json|key4\.db|cookies\.sqlite|places\.sqlite|Network/Cookies|Cookies\.binarycookies|"dataDirectories"'
failures=0
while IFS= read -r -d '' file; do
  hits="$(LC_ALL=C grep -aoE "$pattern" "$file" 2>/dev/null | grep -vx 'cmux Safe Storage' | sort -u || true)"
  if [ -n "$hits" ]; then
    printf '%s:\n%s\n' "${file#"$app"/}" "$(printf '%s\n' "$hits" | sed 's/^/  /')" >&2
    failures=$((failures + 1))
  fi
done < <(find "$app/Contents" -path '*/Chromium Embedded Framework.framework' -prune -o -type f -print0)

if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures file(s) still carry browser-data import targets" >&2
  exit 1
fi
echo "browser-data import targets absent from $app (Chromium Embedded Framework excluded)"
