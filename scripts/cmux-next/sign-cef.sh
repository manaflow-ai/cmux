#!/usr/bin/env bash
# Signs the Chromium engine embedded by embed-cef.sh, inside out:
#
#   Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries/*.dylib
#   Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Helpers/chrome_crashpad_handler
#                                                          (Crashpad builds only, embed-cef.sh)
#   Contents/Frameworks/Chromium Embedded Framework.framework
#   Contents/Frameworks/libcmux_cef_shim.dylib
#   Contents/Frameworks/libcmux_cef_shim_remote.dylib      (Debug builds only, with the host)
#   Contents/Frameworks/<product> Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
#   Contents/MacOS/<product> Chromium Host            (Debug builds only, prototype)
#
# The GPU and Renderer helpers get com.apple.security.cs.allow-jit (V8 and
# the GPU process need it under the hardened runtime); the others get no
# entitlements. One owner for these rules: embed-cef.sh calls this for dev
# builds (ad hoc), scripts/sign-cmux-bundle.sh for Developer ID release
# signing, before the main bundle is signed.
#
# Usage: sign-cef.sh <app> <identity>
#   identity "-" signs ad hoc without the hardened runtime.
# Env: CMUX_TIMESTAMP=none skips the secure timestamp for a real identity.
# Does nothing and exits 0 when the app embeds no CEF framework.
set -euo pipefail

app="${1:?usage: sign-cef.sh <app> <identity>}"
identity="${2:?usage: sign-cef.sh <app> <identity>}"
frameworks="$app/Contents/Frameworks"
framework="$frameworks/Chromium Embedded Framework.framework"
[[ -d "$framework" ]] || exit 0

flags=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  flags+=(--options runtime)
  if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then
    flags+=(--timestamp=none)
  else
    flags+=(--timestamp)
  fi
fi

jit="$(mktemp "${TMPDIR:-/tmp}/cmux-cef-helper-jit.XXXXXX")"
trap 'rm -f "$jit"' EXIT
cat > "$jit" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict>
</plist>
ENT

for lib in "$framework/Versions/A/Libraries/"*.dylib; do
  [[ -f "$lib" ]] && codesign "${flags[@]}" "$lib"
done
# Crashpad's handler is an executable nested in the framework: signed before
# the framework seals it, with the hardened runtime like every other binary and
# no entitlements (Chromium signs chrome_crashpad_handler the same way).
crashpad_handler="$framework/Versions/A/Helpers/chrome_crashpad_handler"
if [[ -f "$crashpad_handler" ]]; then codesign "${flags[@]}" "$crashpad_handler"; fi
codesign "${flags[@]}" "$framework"
for shim in "$frameworks/libcmux_cef_shim.dylib" "$frameworks/libcmux_cef_shim_remote.dylib"; do
  if [[ -f "$shim" ]]; then codesign "${flags[@]}" "$shim"; fi
done
for helper in "$frameworks"/*" Helper.app" "$frameworks"/*" Helper ("*").app"; do
  [[ -d "$helper" ]] || continue
  case "$helper" in
    *" Helper (GPU).app"|*" Helper (Renderer).app")
      codesign "${flags[@]}" --entitlements "$jit" "$helper" ;;
    *)
      codesign "${flags[@]}" "$helper" ;;
  esac
done
# The Chromium host (embed-cef.sh, Debug builds): Chromium's browser process,
# as the app itself is when it runs Chromium in process; a second executable in
# Contents/MacOS, signed before the main bundle as nested code must be.
# A Release bundle has no host: the glob stays literal, and the `if` keeps
# that miss from becoming the script's exit status (a bare `[[ ]] &&` as the
# loop's last command made sign-cef.sh exit 1 and failed Embed CEF).
for host_binary in "$app/Contents/MacOS/"*" Chromium Host"; do
  if [[ -f "$host_binary" ]]; then codesign "${flags[@]}" "$host_binary"; fi
done
