#!/usr/bin/env bash
# Xcode "Embed CEF" phase of the cmux-next target. Puts the Chromium engine
# into the app bundle (plans/cmux-next/browser.md, "Distribution"):
#
#   Contents/Frameworks/Chromium Embedded Framework.framework   (artifact)
#   Contents/Frameworks/libcmux_cef_shim.dylib                  (CEFShim)
#   Contents/Frameworks/<PRODUCT_NAME> Helper.app               (+ GPU, Renderer, Plugin, Alerts)
#
# then signs them inside out with the build's identity (ad hoc for dev
# builds). Xcode signs the outer app afterwards.
#
# Idempotent: copies only what changed and skips signing when the embedded
# stamp (artifact, shim, product name, identity) matches and the framework
# signature still verifies. When the artifact is unavailable (no network, no
# access to the private manaflow-ai/cef release) or CMUX_NEXT_SKIP_CEF=1, it
# removes nothing, embeds nothing, and exits 0: the app then reports the
# Chromium engine as unavailable. CMUX_NEXT_REQUIRE_CEF=1 turns that into a
# build failure (release and CEF verification builds).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_NAME="Chromium Embedded Framework.framework"

if [[ "${CMUX_NEXT_SKIP_CEF:-0}" == "1" ]]; then
  echo "note: CMUX_NEXT_SKIP_CEF=1, not embedding CEF"
  exit 0
fi
if [[ " ${ARCHS:-arm64} " != *" arm64 "* ]]; then
  echo "warning: CEF artifact is arm64 only; ARCHS=${ARCHS:-}, not embedding CEF"
  exit 0
fi

ensure_args=(--optional)
[[ "${CMUX_NEXT_REQUIRE_CEF:-0}" == "1" ]] && ensure_args=()
cef_dir="$("$SCRIPT_DIR/ensure-cef.sh" "${ensure_args[@]}")"
if [[ -z "$cef_dir" ]]; then
  exit 0
fi

app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
frameworks="$app/Contents/Frameworks"
product="${PRODUCT_NAME:?}"
bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:?}"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -z "$identity" ]] && identity="-"

# 1. Shim and helper binary, cached per artifact and shim source.
cache_root="${CMUX_CEF_CACHE_DIR:-$HOME/Library/Caches/cmux/cef}"
shim_out="$cache_root/shim/$(basename "$cef_dir")"
lock="$shim_out.lock"
mkdir -p "$cache_root/shim"
waited=0
until mkdir "$lock" 2>/dev/null; do
  (( waited++ > 600 )) && rm -rf "$lock"
  sleep 1
done
trap 'rm -rf "$lock"' EXIT
"$SCRIPT_DIR/build-cef-shim.sh" "$cef_dir" "$shim_out"
rm -rf "$lock"
trap - EXIT

# 2. Framework and shim.
mkdir -p "$frameworks"
# Signing rewrites the framework binary, so a plain rsync would recopy 367 MiB
# every build. Copy only when the artifact changed.
# Stamps live outside the bundle: any extra file in Contents/Frameworks breaks
# the app's signature ("code object is not signed at all").
stamp_dir="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}}/cmux-cef-embed"
mkdir -p "$stamp_dir"
source_stamp="$stamp_dir/source"
if [[ ! -f "$source_stamp" || ! -d "$frameworks/$FW_NAME" || "$(cat "$source_stamp")" != "$cef_dir" ]]; then
  rm -rf "$frameworks/$FW_NAME"
  ditto "$cef_dir/$FW_NAME" "$frameworks/$FW_NAME"
  printf '%s' "$cef_dir" > "$source_stamp"
fi
# Signing also rewrites the shim and helper binaries, so compare against the
# shim build key, not the bytes.
shim_key="$(cat "$shim_out/.build-key")"
binary_stamp="$stamp_dir/binaries"
[[ -f "$binary_stamp" && "$(cat "$binary_stamp")" == "$shim_key $product" ]] && binaries_current=1 || binaries_current=0
copy_if_changed() {
  if (( binaries_current )) && [[ -f "$2" ]]; then
    return 0
  fi
  # Remove first: overwriting a signed Mach-O in place gets it SIGKILLed.
  rm -f "$2"
  cp "$1" "$2"
}
copy_if_changed "$shim_out/libcmux_cef_shim.dylib" "$frameworks/libcmux_cef_shim.dylib"

# 3. Helper apps. CEF derives the variant names from the base helper name.
min_os="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
kinds=("" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)")
suffixes=("" ".gpu" ".renderer" ".plugin" ".alerts")
wanted=()
for i in "${!kinds[@]}"; do
  name="$product Helper${kinds[$i]}"
  wanted+=("$name.app")
  contents="$frameworks/$name.app/Contents"
  mkdir -p "$contents/MacOS"
  copy_if_changed "$shim_out/cmux-cef-helper" "$contents/MacOS/$name"
  plist="$contents/Info.plist"
  tmp_plist="$(mktemp)"
  cat > "$tmp_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id.helper${suffixes[$i]}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION:-1.0}</string>
  <key>CFBundleVersion</key><string>${CURRENT_PROJECT_VERSION:-1}</string>
  <key>LSEnvironment</key><dict><key>MallocNanoZone</key><string>0</string></dict>
  <key>LSFileQuarantineEnabled</key><true/>
  <key>LSMinimumSystemVersion</key><string>$min_os</string>
  <key>LSUIElement</key><string>1</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
  if ! cmp -s "$tmp_plist" "$plist"; then mv "$tmp_plist" "$plist"; else rm -f "$tmp_plist"; fi
done
# Helpers left over from another product name (a renamed tag).
for existing in "$frameworks"/*" Helper"*.app; do
  [[ -e "$existing" ]] || continue
  base="$(basename "$existing")"
  keep=0
  for w in "${wanted[@]}"; do [[ "$w" == "$base" ]] && keep=1; done
  (( keep )) || rm -rf "$existing"
done

printf '%s' "$shim_key $product" > "$binary_stamp"

# 4. Sign inside out, unless nothing changed since the last signature.
stamp="$stamp_dir/signed"
stamp_value="$(basename "$cef_dir") $shim_key $product $identity"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$stamp_value" ]] &&
  codesign --verify "$frameworks/$FW_NAME" >/dev/null 2>&1 &&
  codesign --verify "$frameworks/$product Helper.app" >/dev/null 2>&1; then
  exit 0
fi

sign_flags=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  sign_flags+=(--timestamp --options runtime)
fi
jit_entitlements="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}}/cmux-cef-helper-jit.entitlements"
mkdir -p "$(dirname "$jit_entitlements")"
cat > "$jit_entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict>
</plist>
ENT

for lib in "$frameworks/$FW_NAME/Libraries/"*.dylib; do
  codesign "${sign_flags[@]}" "$lib"
done
codesign "${sign_flags[@]}" "$frameworks/$FW_NAME"
codesign "${sign_flags[@]}" "$frameworks/libcmux_cef_shim.dylib"
for i in "${!kinds[@]}"; do
  helper="$frameworks/$product Helper${kinds[$i]}.app"
  case "${kinds[$i]}" in
    " (GPU)"|" (Renderer)") codesign "${sign_flags[@]}" --entitlements "$jit_entitlements" "$helper" ;;
    *) codesign "${sign_flags[@]}" "$helper" ;;
  esac
done
printf '%s' "$stamp_value" > "$stamp"
echo "==> embedded CEF $(basename "$cef_dir") into $app"
