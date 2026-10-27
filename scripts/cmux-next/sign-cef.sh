#!/usr/bin/env bash
# Signs the Chromium engine embedded by embed-cef.sh, inside out:
#
#   Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries/*.dylib
#   Contents/Frameworks/Chromium Embedded Framework.framework
#   Contents/Frameworks/libcmux_cef_shim.dylib
#   Contents/Frameworks/libcmux_cef_shim_remote.dylib      (with the host)
#   Contents/Frameworks/<product> Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
#   Contents/MacOS/<product> Chromium Host            (Chromium's browser process)
#
# The GPU and Renderer helpers get com.apple.security.cs.allow-jit (V8 and
# the GPU process need it under the hardened runtime); the others get no
# entitlements. One owner for these rules: embed-cef.sh calls this for dev
# builds (ad hoc), scripts/sign-cmux-bundle.sh for Developer ID release
# signing, before the main bundle is signed.
#
# The host is the app's browser process, as Chrome's main executable is
# (chrome/installer/mac/signing/parts.py: the app part keeps the base bundle
# id; only helpers get suffixed ids). It runs with the app's bundle and
# Info.plist (plans/cmux-next/cef-helper-app-DESIGN.md 3.1), so it is signed
# with the app's bundle id as its identifier: its designated requirement is
# then the app's, which the "Chromium Safe Storage" keychain ACL, TCC and the
# host adoption socket (task 150) match. Hardened runtime and no entitlements:
# the browser process does not JIT (chrome/app/app-entitlements.plist has no
# allow-jit; Renderer and GPU keep it).
#
# Usage: sign-cef.sh <app> <identity>
#   identity "-" signs ad hoc without the hardened runtime.
#        sign-cef.sh --verify-host <app>
#   checks a release-signed host after the app is signed (sign-cmux-bundle.sh):
#   valid, hardened runtime, no entitlements, the app's identifier and team.
#   Exits 0 when the app carries no host.
# Env: CMUX_TIMESTAMP=none skips the secure timestamp for a real identity.
# Signing does nothing and exits 0 when the app embeds no CEF framework.
set -euo pipefail

# The app's CFBundleIdentifier, or nothing when it has no Info.plist yet.
app_bundle_id() { # <app>
  local plist="$1/Contents/Info.plist"
  [[ -f "$plist" ]] || return 0
  /usr/bin/python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get("CFBundleIdentifier", ""))' "$plist"
}

# `codesign -d --verbose=2` fields of <path>, one "key=value" per line:
# identifier, team and flags (the CodeDirectory flag names, comma separated).
signature_fields() { # <path>
  codesign -d --verbose=2 "$1" 2>&1 | sed -n \
    -e 's/^Identifier=\(.*\)$/identifier=\1/p' \
    -e 's/^TeamIdentifier=\(.*\)$/team=\1/p' \
    -e 's/^CodeDirectory .* flags=0x[0-9a-fA-F]*(\([^)]*\)).*$/flags=\1/p'
}
field() { # <fields> <key>
  sed -n "s/^$2=//p" <<<"$1" | head -n 1
}

verify_host() { # <app>
  local app="$1" host_binary found=0 want_id want_team host_fields id team entitlements
  want_id="$(app_bundle_id "$app")"
  [[ -n "$want_id" ]] || { echo "error: $app has no CFBundleIdentifier" >&2; return 1; }
  want_team="$(field "$(signature_fields "$app")" team)"
  for host_binary in "$app/Contents/MacOS/"*" Chromium Host"; do
    [[ -f "$host_binary" ]] || continue
    found=1
    codesign --verify --strict --verbose=2 "$host_binary" ||
      { echo "error: the Chromium host's signature does not verify: $host_binary" >&2; return 1; }
    host_fields="$(signature_fields "$host_binary")"
    id="$(field "$host_fields" identifier)"
    team="$(field "$host_fields" team)"
    [[ ",$(field "$host_fields" flags)," == *",runtime,"* ]] ||
      { echo "error: the Chromium host is not signed with the hardened runtime: $host_binary" >&2; return 1; }
    [[ "$id" == "$want_id" ]] ||
      { echo "error: the Chromium host's identifier is '$id', not the app's '$want_id'" >&2; return 1; }
    [[ -n "$team" && "$team" != "not set" && "$team" == "$want_team" ]] ||
      { echo "error: the Chromium host's team '$team' is not the app's '$want_team'" >&2; return 1; }
    entitlements="$(codesign -d --entitlements :- "$host_binary" 2>/dev/null || true)"
    if grep -q '<key>' <<<"$entitlements"; then
      echo "error: the Chromium host carries entitlements (it needs none, never allow-jit): $host_binary" >&2
      return 1
    fi
    echo "==> Chromium host signed as nested code: $(basename "$host_binary") ($id, team $team, hardened runtime, no entitlements)"
  done
  (( found )) || echo "note: $app carries no Chromium host"
  return 0
}

if [[ "${1:-}" == "--verify-host" ]]; then
  verify_host "${2:?usage: sign-cef.sh --verify-host <app>}"
  exit 0
fi

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
# The Chromium host (embed-cef.sh): Chromium's browser process, as the app
# itself is when it runs Chromium in process; a second executable in
# Contents/MacOS, signed last here and before the main bundle, as nested code
# must be, with the app's identifier (see the top). A bundle whose host did not
# build has none: the glob stays literal, and the `if` keeps that miss from
# becoming the script's exit status (a bare `[[ ]] &&` as the loop's last
# command made sign-cef.sh exit 1 and failed Embed CEF).
# Xcode's Embed CEF phase may run before it writes Info.plist; its build
# setting names the same id.
bundle_id="$(app_bundle_id "$app")"
[[ -n "$bundle_id" ]] || bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:-}"
for host_binary in "$app/Contents/MacOS/"*" Chromium Host"; do
  [[ -f "$host_binary" ]] || continue
  if [[ -n "$bundle_id" ]]; then
    codesign "${flags[@]}" --identifier "$bundle_id" "$host_binary"
  elif [[ "$identity" == "-" ]]; then
    codesign "${flags[@]}" "$host_binary"  # ad hoc outside Xcode, with no id to give
  else
    echo "error: $app has no CFBundleIdentifier for the Chromium host's signature" >&2
    exit 1
  fi
done
