#!/usr/bin/env bash
# Signs the Chromium engine embedded by embed-cef.sh, inside out:
#
#   Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries/*.dylib
#   Contents/Frameworks/Chromium Embedded Framework.framework
#   Contents/Frameworks/libcmux_cef_shim.dylib
#   Contents/Frameworks/<product> Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
#   Contents/MacOS/<product> Chromium Host            (every configuration)
#
# The GPU and Renderer helpers get com.apple.security.cs.allow-jit (V8 and
# the GPU process need it under the hardened runtime); the other helpers get
# no entitlements.
#
# The Chromium host is Chromium's browser process. It is signed as Chrome
# signs its browser process (chrome/app/app-entitlements.plist): no cs.*
# exception (no allow-jit, no allow-unsigned-executable-memory, no
# disable-library-validation; the framework it loads has the app's team), and
# only the hardened runtime's resource-access keys for what the browser process
# itself opens: audio input, camera and location (the HOST_ENTITLEMENTS list).
# Its signing identifier is <app bundle id>.chromium-host, as Chrome's nested
# code is com.google.Chrome.helper, so its designated requirement does not
# change with the product name.
#
# One owner for these rules: embed-cef.sh calls this for dev builds (ad hoc),
# scripts/sign-cmux-bundle.sh for Developer ID release signing, before the
# main bundle is signed, and with --verify-host after it.
#
# Usage: sign-cef.sh <app> <identity>
#   identity "-" signs ad hoc without the hardened runtime.
#        sign-cef.sh --verify-host <app>
#   checks a Developer ID signed app's Chromium host: a strict signature, the
#   hardened runtime, a secure timestamp, identifier <bundle id>.chromium-host,
#   the app's team, and exactly the HOST_ENTITLEMENTS keys. Exits 0 when the
#   app has no host.
# Env: CMUX_TIMESTAMP=none skips the secure timestamp for a real identity (and
#      its check in --verify-host).
#      CMUX_CEF_BUNDLE_ID: the app's bundle id; default its Info.plist's
#      CFBundleIdentifier (embed-cef.sh passes it: Xcode writes the
#      Info.plist after the Embed CEF phase).
# Signing does nothing and exits 0 when the app embeds no CEF framework.
set -euo pipefail

HOST_ENTITLEMENTS=(
  com.apple.security.device.audio-input
  com.apple.security.device.camera
  com.apple.security.personal-information.location
)

usage="usage: sign-cef.sh <app> <identity> | sign-cef.sh --verify-host <app>"
mode=sign
if [[ "${1:-}" == "--verify-host" ]]; then
  mode=verify-host
  shift
fi
app="${1:?$usage}"
frameworks="$app/Contents/Frameworks"

host_binaries() { # the app's Chromium host executables, one per line
  local host
  for host in "$app/Contents/MacOS/"*" Chromium Host"; do
    if [[ -f "$host" ]]; then printf '%s\n' "$host"; fi
  done
}
host_identifier() {
  local bundle_id="${CMUX_CEF_BUNDLE_ID:-}"
  if [[ -z "$bundle_id" ]]; then
    bundle_id="$(/usr/bin/python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleIdentifier"])' \
      "$app/Contents/Info.plist" 2>/dev/null)" || bundle_id=""
  fi
  if [[ -z "$bundle_id" ]]; then
    echo "error: sign-cef.sh: no bundle id for the Chromium host (set CMUX_CEF_BUNDLE_ID or give $app an Info.plist)" >&2
    return 1
  fi
  printf '%s.chromium-host' "$bundle_id"
}

if [[ "$mode" == verify-host ]]; then
  hosts="$(host_binaries)"
  if [[ -z "$hosts" ]]; then
    echo "note: sign-cef.sh: $app has no Chromium host"
    exit 0
  fi
  fail() { echo "error: sign-cef.sh --verify-host: $*" >&2; exit 1; }
  field() { sed -n "s/^$1=//p" <<<"$2" | head -n 1; }
  expected="$(host_identifier)" || exit 1
  expected_keys="$(printf '%s\n' "${HOST_ENTITLEMENTS[@]}" | sort)"
  app_info="$(codesign -d --verbose=2 "$app" 2>&1)" || fail "cannot read the signature of $app"
  app_team="$(field TeamIdentifier "$app_info")"
  [[ -n "$app_team" && "$app_team" != "not set" ]] || fail "$app has no signing team (not Developer ID signed)"
  while IFS= read -r host; do
    codesign --verify --strict --verbose=2 "$host" || fail "codesign --verify --strict failed on $host"
    info="$(codesign -d --verbose=2 "$host" 2>&1)" || fail "cannot read the signature of $host"
    identifier="$(field Identifier "$info")"
    [[ "$identifier" == "$expected" ]] || fail "$host has identifier '$identifier', not '$expected'"
    grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$info" || fail "$host is not signed with the hardened runtime"
    team="$(field TeamIdentifier "$info")"
    [[ "$team" == "$app_team" ]] || fail "$host is signed by team '${team:-none}', the app by '$app_team'"
    if [[ "${CMUX_TIMESTAMP:-}" != "none" ]]; then
      grep -q '^Timestamp=' <<<"$info" || fail "$host has no secure timestamp (notarization needs one)"
    fi
    plist="$(codesign -d --entitlements :- "$host" 2>/dev/null)" || fail "cannot read the entitlements of $host"
    keys="$(grep -o '<key>[^<]*</key>' <<<"$plist" | sed 's/<\/\{0,1\}key>//g' | sort || true)"
    [[ "$keys" == "$expected_keys" ]] \
      || fail "$host has entitlements [$(paste -sd ' ' - <<<"$keys")], not [$(paste -sd ' ' - <<<"$expected_keys")]"
    echo "==> Chromium host signature OK: $host ($identifier, team $team, hardened runtime, no cs.* entitlement)"
  done <<<"$hosts"
  exit 0
fi

identity="${2:?$usage}"
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

entitlements_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cef-entitlements.XXXXXX")"
trap 'rm -rf "$entitlements_dir"' EXIT
write_entitlements() { # <file> <key>...: a plist with each key set to true
  local file="$1" key
  shift
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' '<dict>'
    for key in "$@"; do printf '  <key>%s</key><true/>\n' "$key"; done
    printf '%s\n' '</dict>' '</plist>'
  } > "$file"
}
jit="$entitlements_dir/helper-jit.plist"
write_entitlements "$jit" com.apple.security.cs.allow-jit
host_entitlements="$entitlements_dir/chromium-host.plist"
write_entitlements "$host_entitlements" "${HOST_ENTITLEMENTS[@]}"

for lib in "$framework/Versions/A/Libraries/"*.dylib; do
  [[ -f "$lib" ]] && codesign "${flags[@]}" "$lib"
done
codesign "${flags[@]}" "$framework"
if [[ -f "$frameworks/libcmux_cef_shim.dylib" ]]; then
  codesign "${flags[@]}" "$frameworks/libcmux_cef_shim.dylib"
fi
for helper in "$frameworks"/*" Helper.app" "$frameworks"/*" Helper ("*").app"; do
  [[ -d "$helper" ]] || continue
  case "$helper" in
    *" Helper (GPU).app"|*" Helper (Renderer).app")
      codesign "${flags[@]}" --entitlements "$jit" "$helper" ;;
    *)
      codesign "${flags[@]}" "$helper" ;;
  esac
done
# The Chromium host (embed-cef.sh): a second executable in Contents/MacOS,
# signed last here, after the framework it loads and the helpers it starts,
# and before the main bundle, as nested code must be. A bundle without a host
# (CEF skipped, or a dev host that did not build) signs none.
hosts="$(host_binaries)"
if [[ -n "$hosts" ]]; then
  identifier="$(host_identifier)"
  while IFS= read -r host_binary; do
    codesign "${flags[@]}" --identifier "$identifier" --entitlements "$host_entitlements" "$host_binary"
  done <<<"$hosts"
fi
