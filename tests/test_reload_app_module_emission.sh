#!/usr/bin/env bash
# reload.sh skips the app's separate Swift module emission to make rebuilds faster. On
# Xcode 26.2 and 26.3 that build stops at the module merge with "type mismatch of
# function ... but used in a swift module as ...", so a plain reload of main fails there.
# reload.sh must emit the module on those versions without being told to.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Use the real functions, not copies.
eval "$(awk '/^selected_xcode_version\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
eval "$(awk '/^reload_skips_app_module_emission\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
declare -F selected_xcode_version >/dev/null || fail "selected_xcode_version not found in reload.sh"
declare -F reload_skips_app_module_emission >/dev/null \
  || fail "reload_skips_app_module_emission not found in reload.sh"

unset CMUX_RELOAD_APP_EMIT_MODULE
for version in 26.2 26.2.1 26.3 26.3.1; do
  if reload_skips_app_module_emission "$version"; then
    fail "Xcode $version fails the module merge, so reload must emit the app's module there"
  fi
done
for version in 16.2 26.0 26.1 26.4 26.20 26.30 ""; do
  reload_skips_app_module_emission "$version" \
    || fail "Xcode '$version' is not known to fail, so reload must keep skipping the module"
done

# The variable still decides in both directions when it is set.
CMUX_RELOAD_APP_EMIT_MODULE=1 reload_skips_app_module_emission 26.1 \
  && fail "CMUX_RELOAD_APP_EMIT_MODULE=1 must emit the module on any Xcode"
CMUX_RELOAD_APP_EMIT_MODULE=0 reload_skips_app_module_emission 26.3 \
  || fail "CMUX_RELOAD_APP_EMIT_MODULE=0 must keep the shortcut on an affected Xcode"

# The version comes from the Xcode the build will use.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\nprintf "Xcode 26.3\\nBuild version 17C529\\n"\n' > "$tmp/xcodebuild"
chmod +x "$tmp/xcodebuild"
[[ "$(PATH="$tmp:$PATH" selected_xcode_version)" == "26.3" ]] \
  || fail "selected_xcode_version did not read the version from xcodebuild -version"
printf '#!/bin/sh\nexit 1\n' > "$tmp/xcodebuild"
[[ -z "$(PATH="$tmp:$PATH" selected_xcode_version)" ]] \
  || fail "selected_xcode_version must print nothing when xcodebuild cannot answer"

# The build must take its decision from the function.
grep -Fq 'if reload_skips_app_module_emission "$(selected_xcode_version)"; then' "$ROOT/scripts/reload.sh" \
  || fail "reload.sh does not decide the app's module emission through reload_skips_app_module_emission"

echo "PASS: reload.sh emits the app's module on Xcode versions that fail the module merge"
