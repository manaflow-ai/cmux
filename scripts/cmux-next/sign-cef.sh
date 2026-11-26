#!/usr/bin/env bash
# Signs the Chromium engine embedded by embed-cef.sh, inside out:
#
#   Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries/*.dylib
#   Contents/Frameworks/Chromium Embedded Framework.framework
#   Contents/Frameworks/libcmux_cef_shim.dylib
#   Contents/Frameworks/<product> Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
#   Contents/MacOS/<product> Chromium Host            (Debug builds only, prototype)
#
# The plain, GPU and Renderer helpers get com.apple.security.cs.allow-jit (V8
# and the GPU process need it under the hardened runtime); the others get no
# entitlements. The plain helper needs it since CEF 156 (cef-156.0.15-cmux.43):
# Chromium 156 starts renderer and extension processes from the plain
# "<product> Helper.app", and V8 aborts there without allow-jit ("Failed to
# reserve virtual memory for CodeRange"). The plain helper also gets
# com.apple.security.cs.disable-library-validation: Chromium runs the Widevine
# CDM (media.mojom.CdmServiceBroker) in it, and the CDM the component updater
# installs is signed by Google's team (EQHXZ8M8AV), so under the hardened
# runtime the kernel refused to map it ("Library Validation failed: Rejecting
# .../libwidevinecdm.dylib", NIGHTLY 4529584712101) and every protected-media
# page said "CreateCdmFunc not available": Spotify and Netflix could not play.
# Chrome needs no exception (one team signs both); other Chromium browsers
# signed by their own team carry it on the helper that loads the CDM.
# One owner for these rules: embed-cef.sh calls this for dev
# builds (ad hoc), scripts/sign-cmux-bundle.sh for Developer ID release
# signing, before the main bundle is signed.
#
# Usage: sign-cef.sh <app> <identity>
#   identity "-" signs ad hoc without the hardened runtime.
# Env: CMUX_TIMESTAMP=none skips the secure timestamp for a real identity.
#   CMUX_CEF_REUSE_FRAMEWORK=<Chromium Embedded Framework.framework> from an
#   earlier signed build (the nightly passes the one the feed serves): when it
#   holds the same code signed the same way as the framework just signed here,
#   it takes that framework's place. A fresh signature differs in every build
#   (the signing time and Apple's time stamp sit in its CMS blob), so the 270 MB
#   framework changed in every update and every Sparkle delta had to diff it.
#   Reused, its bytes stay the same until the Chromium engine itself changes,
#   and BinaryDelta leaves it out of the delta (Lawrence, relayed by Leo: "if
#   chromium version doesn't change, update doesnt have to include chromium
#   parts"). Anything that differs keeps the fresh signature.
# Does nothing and exits 0 when the app embeds no CEF framework.
set -euo pipefail

app="${1:?usage: sign-cef.sh <app> <identity>}"
identity="${2:?usage: sign-cef.sh <app> <identity>}"
frameworks="$app/Contents/Frameworks"
framework="$frameworks/Chromium Embedded Framework.framework"
[[ -d "$framework" ]] || exit 0

flags=(--force --sign "$identity")
# Every signature goes through codesign-retry.sh: Apple's timestamp service fails for a moment now and then.
sign_tool="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/codesign-retry.sh"
if [[ "$identity" != "-" ]]; then
  flags+=(--options runtime)
  if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then
    flags+=(--timestamp=none)
  else
    flags+=(--timestamp)
  fi
fi

jit="$(mktemp "${TMPDIR:-/tmp}/cmux-cef-helper-jit.XXXXXX")"
cdm="$(mktemp "${TMPDIR:-/tmp}/cmux-cef-helper-cdm.XXXXXX")"
trap 'rm -f "$jit" "$cdm"' EXIT
cat > "$jit" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict>
</plist>
ENT
# The plain helper: allow-jit, and the Widevine CDM (Google's signature) may load.
cat > "$cdm" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
ENT

# fingerprint <code>: what `codesign -d` shows of each architecture's signature
# but the signing time, time stamp and CMS size. The CodeDirectory hashes cover
# the code, Info.plist, sealed resources, requirements and flags, so two equal
# fingerprints are the same code signed by the same signer the same way.
fingerprint() {
  local code="$1" bin="$1" arch
  if [[ -d "$code" ]]; then bin="$code/Versions/A/$(basename "$code" .framework)"; fi
  for arch in $(lipo -archs "$bin" 2>/dev/null || true); do
    echo "arch $arch"
    { codesign -d -vvv --arch "$arch" "$code" 2>&1 || true; } |
      grep -E '^(Identifier|Format|CodeDirectory|CandidateCDHash|CDHash|Authority|TeamIdentifier|Runtime Version|Sealed Resources|Internal requirements)' || true
  done
}
# framework_fingerprint <framework>: its file list, then the fingerprints of the
# framework and of each library in it.
framework_fingerprint() {
  local lib
  (cd "$1" && find . | LC_ALL=C sort)
  fingerprint "$1"
  for lib in "$1/Versions/A/Libraries/"*.dylib; do
    if [[ -f "$lib" ]]; then echo "library ${lib##*/}"; fingerprint "$lib"; fi
  done
}
# not_reusable <signed here> <earlier copy> <its fingerprint here>: prints why
# the earlier copy may not take the place of the signature made here, or nothing.
not_reusable() {
  if [[ ! -e "$2" ]]; then
    echo "it is missing"
  elif [[ "$3" != *CDHash=* ]]; then
    echo "the copy signed here shows no CDHash"
  elif [[ "$3" != "$4" ]]; then
    echo "it holds other code or another signature"
  elif [[ "$identity" != "-" && "${CMUX_TIMESTAMP:-}" != "none" ]] &&
    ! { codesign -d -vvv "$2" 2>&1 || true; } | grep -q '^Timestamp='; then
    echo "it has no secure time stamp"
  elif ! codesign --verify --strict "$2" >/dev/null 2>&1; then
    echo "its signature does not verify"
  fi
}
reuse="${CMUX_CEF_REUSE_FRAMEWORK:-}"
[[ -n "$reuse" && -d "$reuse" ]] || reuse=""

for lib in "$framework/Versions/A/Libraries/"*.dylib; do
  [[ -f "$lib" ]] || continue
  "$sign_tool" "${flags[@]}" "$lib"
  # The framework seals each library's whole file, signature included, so a
  # library's fresh time stamp alone would change the framework's CDHash (two
  # nightly-next builds with one engine pin, 2026-11-17). Same code, same
  # signer: the earlier build's signed library, byte for byte.
  if [[ -n "$reuse" ]]; then
    earlier="$reuse/Versions/A/Libraries/${lib##*/}"
    why="$(not_reusable "$lib" "$earlier" "$(fingerprint "$lib")" "$(fingerprint "$earlier" 2>/dev/null || true)")"
    if [[ -z "$why" ]]; then cp -p "$earlier" "$lib"; fi
  fi
done
"$sign_tool" "${flags[@]}" "$framework"

if [[ -n "$reuse" ]]; then
  why="$(not_reusable "$framework" "$reuse" "$(framework_fingerprint "$framework")" "$(framework_fingerprint "$reuse")")"
  if [[ -z "$why" ]]; then
    staged="$frameworks/.cef-reuse"
    rm -rf "$staged"
    mkdir "$staged"
    ditto "$reuse" "$staged/${framework##*/}"
    if codesign --verify --strict "$staged/${framework##*/}"; then
      rm -rf "$framework"
      mv "$staged/${framework##*/}" "$framework"
      echo "sign-cef: reused the signed Chromium framework of $reuse (same code, same signer)"
    else
      why="its copy does not verify"
    fi
    rm -rf "$staged"
  fi
  if [[ -n "$why" ]]; then echo "sign-cef: kept the fresh Chromium framework signature; $reuse: $why"; fi
fi

if [[ -f "$frameworks/libcmux_cef_shim.dylib" ]]; then
  "$sign_tool" "${flags[@]}" "$frameworks/libcmux_cef_shim.dylib"
fi
for helper in "$frameworks"/*" Helper.app" "$frameworks"/*" Helper ("*").app"; do
  [[ -d "$helper" ]] || continue
  case "$helper" in
    *" Helper.app")
      "$sign_tool" "${flags[@]}" --entitlements "$cdm" "$helper" ;;
    *" Helper (GPU).app"|*" Helper (Renderer).app")
      "$sign_tool" "${flags[@]}" --entitlements "$jit" "$helper" ;;
    *)
      "$sign_tool" "${flags[@]}" "$helper" ;;
  esac
done
# The Chromium host (embed-cef.sh, Debug builds): Chromium's browser process,
# a second executable in Contents/MacOS (its main bundle is the app, so the
# helpers' sandbox lets them read the framework), signed before the app is.
# A Release bundle has no host: the glob stays literal, and the `if` keeps
# that miss from becoming the script's exit status (a bare `[[ ]] &&` as the
# loop's last command made sign-cef.sh exit 1 and failed Embed CEF).
for host in "$app/Contents/MacOS/"*" Chromium Host"; do
  if [[ -f "$host" ]]; then "$sign_tool" "${flags[@]}" "$host"; fi
done
