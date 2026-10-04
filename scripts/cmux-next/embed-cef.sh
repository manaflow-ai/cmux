#!/usr/bin/env bash
# Xcode "Embed CEF" phase of the cmux-next target. Puts the Chromium engine
# into the app bundle (plans/cmux-next/browser.md, "Distribution"):
#
#   Contents/Frameworks/Chromium Embedded Framework.framework   (artifact)
#   Contents/Frameworks/libcmux_cef_shim.dylib                  (CEFShim)
#   Contents/Frameworks/<PRODUCT_NAME> Helper.app               (+ GPU, Renderer, Plugin, Alerts)
#
# then signs them inside out with the build's identity (ad hoc for dev
# builds) through sign-cef.sh. Xcode signs the outer app afterwards; release
# signing (scripts/sign-cmux-bundle.sh) re-signs them with sign-cef.sh.
#
# The artifact ships CEF's flat framework (binary, Libraries/, Resources/ at
# the top). Xcode's product validation rejects that layout ("did not contain
# an Info.plist"), so the framework is embedded as a standard versioned
# bundle: Versions/A/{binary,Libraries,Resources}, Versions/Current -> A, and
# top-level symlinks. CEF and the helpers keep using the top-level paths.
#
# Idempotent: copies only what changed and skips signing when the embedded
# stamp (artifact, layout, shim, product name, identity) matches and the
# framework signature still verifies. When the artifact is unavailable (no
# network, no access to the private manaflow-ai/cef release) or
# CMUX_NEXT_SKIP_CEF=1, it embeds nothing and exits 0: the app then reports
# the Chromium engine as unavailable. A CEF embedded by an earlier build is
# kept when its layout is valid and removed when it is the old flat layout,
# which would fail validation. CMUX_NEXT_REQUIRE_CEF=1 turns a missing
# artifact into a build failure (release and CEF verification builds).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_NAME="Chromium Embedded Framework.framework"
FW_BINARY="Chromium Embedded Framework"
source "$SCRIPT_DIR/cef-locale-allowlist.sh"
# Bump when the embedded layout changes so existing app bundles are redone.
LAYOUT="versioned-3-locale-fallback-allowlist"

app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
frameworks="$app/Contents/Frameworks"

# Removes a framework left by a build that used the flat layout, with the
# shim and helpers that belong to it. Used when nothing will replace it.
remove_invalid_embed() {
  local fw="$frameworks/$FW_NAME"
  [[ -e "$fw" ]] || return 0
  [[ -L "$fw/Versions/Current" ]] && return 0
  echo "note: removing a flat-layout CEF framework left by an earlier build"
  rm -rf "$fw" "$frameworks/libcmux_cef_shim.dylib"
  for helper in "$frameworks"/*" Helper"*.app; do
    [[ -e "$helper" ]] && rm -rf "$helper"
  done
  return 0
}

if [[ "${CMUX_NEXT_SKIP_CEF:-0}" == "1" ]]; then
  echo "note: CMUX_NEXT_SKIP_CEF=1, not embedding CEF"
  remove_invalid_embed
  exit 0
fi
# Which artifacts this build needs. A universal build (ARCHS has both) embeds
# a lipo-merged framework (merge-cef-universal.sh) and a universal shim when
# the manifest has an x86_64 artifact; without one it embeds the arm64 engine
# and scripts/cmux-next/drop-cef-without-arch.sh removes it from the thin
# x86_64 variant. An x86_64-only build uses the x86_64 artifact alone.
want_arm=0; want_x86=0
[[ " ${ARCHS:-arm64} " == *" arm64 "* ]] && want_arm=1
[[ " ${ARCHS:-arm64} " == *" x86_64 "* ]] && want_x86=1
ensure_args=(--optional)
[[ "${CMUX_NEXT_REQUIRE_CEF:-0}" == "1" ]] && ensure_args=()
arm_dir=""; x86_dir=""
if (( want_arm )); then
  # `${a[@]+...}`: bash 3.2 (Xcode's /bin/bash) treats an empty array as
  # unset under `set -u`, so CMUX_NEXT_REQUIRE_CEF=1 failed here.
  arm_dir="$("$SCRIPT_DIR/ensure-cef.sh" ${ensure_args[@]+"${ensure_args[@]}"})"
fi
if (( want_x86 )); then
  # Optional even with CMUX_NEXT_REQUIRE_CEF while the x86_64 engine is new:
  # a universal build then keeps the arm64 engine.
  x86_dir="$("$SCRIPT_DIR/ensure-cef.sh" --optional --arch x86_64)"
fi
cache_root="$("$SCRIPT_DIR/cef-cache-root.sh")"
shim_archs=()
if [[ -n "$arm_dir" && -n "$x86_dir" ]]; then
  cef_dir="$("$SCRIPT_DIR/merge-cef-universal.sh" "$arm_dir" "$x86_dir" "$cache_root/universal" | tail -n 1)"
  shim_archs=(arm64 x86_64)
elif [[ -n "$arm_dir" ]]; then
  cef_dir="$arm_dir"; shim_archs=(arm64)
elif [[ -n "$x86_dir" ]]; then
  cef_dir="$x86_dir"; shim_archs=(x86_64)
else
  cef_dir=""
fi
if [[ -z "$cef_dir" ]]; then
  echo "warning: no CEF artifact for ARCHS=${ARCHS:-}; not embedding CEF"
  remove_invalid_embed
  exit 0
fi

product="${PRODUCT_NAME:?}"
bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:?}"
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -z "$identity" ]] && identity="-"

# 1. Shim and helper binary, cached per artifact and shim source. The
# cache is content-addressed and its entries are immutable
# (build-cef-shim.sh), so concurrent builds from several worktrees share it
# without a lock.
# Each arch's shim builds against that arch's own dist; a universal build
# lipo-merges the two into a content-addressed directory.
shim_for() { # <arch> <dist>
  CMUX_CEF_ARCH="$1" "$SCRIPT_DIR/build-cef-shim.sh" "$2" "$cache_root/shim" | tail -n 1
}
if (( ${#shim_archs[@]} == 2 )); then
  arm_shim="$(shim_for arm64 "$arm_dir")"
  x86_shim="$(shim_for x86_64 "$x86_dir")"
  universal_key="$(printf '%s %s' "$(cat "$arm_shim/.build-key")" "$(cat "$x86_shim/.build-key")" | shasum -a 256 | awk '{print $1}')"
  shim_out="$cache_root/shim/universal-${universal_key:0:16}"
  if [[ ! -f "$shim_out/.build-key" ]]; then
    shim_tmp="$(mktemp -d "$cache_root/shim/.universal.XXXXXX")"
    lipo -create "$arm_shim/libcmux_cef_shim.dylib" "$x86_shim/libcmux_cef_shim.dylib" -output "$shim_tmp/libcmux_cef_shim.dylib"
    lipo -create "$arm_shim/cmux-cef-helper" "$x86_shim/cmux-cef-helper" -output "$shim_tmp/cmux-cef-helper"
    chmod +x "$shim_tmp/cmux-cef-helper"
    printf '%s' "$universal_key" > "$shim_tmp/.build-key"
    /usr/bin/python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$shim_tmp" "$shim_out" 2>/dev/null || rm -rf "$shim_tmp"
  fi
else
  shim_out="$(shim_for "${shim_archs[0]}" "$cef_dir")"
fi

# 2. Framework and shim.
mkdir -p "$frameworks"
# Signing rewrites the framework binary, so a plain rsync would recopy 367 MiB
# every build. Copy only when the artifact changed.
# Stamps live outside the bundle: any extra file in Contents/Frameworks breaks
# the app's signature ("code object is not signed at all").
stamp_dir="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}}/cmux-cef-embed"
mkdir -p "$stamp_dir"
source_stamp="$stamp_dir/source"
source_value="$cef_dir $LAYOUT"
# Chromium ships 228 locale catalogs. Keep every catalog CEF resolves for
# cmux's 21 app languages and their regional macOS variants, including
# es_419, pt_PT and en_GB. Unsupported app languages bs and km fall back to en.
CEF_LOCALE_ALLOWLIST="$(cef_locale_allowlist)"
keep_cef_locale() {
  case $'\n'"$CEF_LOCALE_ALLOWLIST"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}
prune_cef_locales() {
  local resources="$1" locale_dir locale
  for locale_dir in "$resources"/*.lproj; do
    [[ -d "$locale_dir" ]] || continue
    locale="$(basename "$locale_dir" .lproj)"
    if ! keep_cef_locale "$locale"; then
      rm -rf "$locale_dir"
    fi
  done
}

if [[ ! -f "$source_stamp" || ! -L "$frameworks/$FW_NAME/Versions/Current" || "$(cat "$source_stamp")" != "$source_value" ]]; then
  fw="$frameworks/$FW_NAME"
  rm -rf "$fw"
  mkdir -p "$fw/Versions/A"
  for item in "$FW_BINARY" Libraries Resources; do
    ditto "$cef_dir/$FW_NAME/$item" "$fw/Versions/A/$item"
  done
  prune_cef_locales "$fw/Versions/A/Resources"
  ln -s A "$fw/Versions/Current"
  for item in "$FW_BINARY" Libraries Resources; do
    ln -s "Versions/Current/$item" "$fw/$item"
  done
  printf '%s' "$source_value" > "$source_stamp"
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
stamp_value="$(basename "$cef_dir") $LAYOUT $shim_key $product $identity"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$stamp_value" ]] &&
  codesign --verify "$frameworks/$FW_NAME" >/dev/null 2>&1 &&
  codesign --verify "$frameworks/$product Helper.app" >/dev/null 2>&1; then
  exit 0
fi

"$SCRIPT_DIR/sign-cef.sh" "$app" "$identity"
printf '%s' "$stamp_value" > "$stamp"
echo "==> embedded CEF $(basename "$cef_dir") into $app"
