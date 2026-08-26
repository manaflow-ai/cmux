#!/bin/bash
# Xcode build phase: embeds the CEF framework and helper bundles into the app.
#
# The framework comes from the machine-wide cache maintained by
# scripts/ensure-cef.sh; nothing CEF-related is checked into the repository.
# Helpers use fixed names ("cmux CEF Helper*") because the shim points
# CefSettings.browser_subprocess_path at them, keeping tagged dev builds with
# per-tag product names working unchanged.
set -euo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# CEF is an optional renderer. A normal/offline build must remain usable with
# the streamed Chromium fallback, so only an explicit opt-in may download the
# ~400 MB framework. A previously populated machine cache is still reused.
CEF_SOURCE_ARGS=()
CEF_ERROR_LOG="$(mktemp "${TMPDIR:-/tmp}/cmux-cef-ensure.XXXXXX")"
trap 'rm -f "$CEF_ERROR_LOG"' EXIT
if [[ "${CMUX_CEF_ALLOW_DOWNLOAD:-0}" != "1" ]]; then
  CEF_SOURCE_ARGS+=(--check)
fi
read -r -a CEF_ARCHES <<< "${ARCHS:-$(uname -m)}"
if [[ "${#CEF_ARCHES[@]}" -eq 0 ]]; then
  CEF_ARCHES=("$(uname -m)")
fi
CEF_SOURCES=()
for CEF_ARCH in "${CEF_ARCHES[@]}"; do
  if ! FRAMEWORK_SOURCE="$(CMUX_CEF_ARCH="$CEF_ARCH" "$SRCROOT/scripts/ensure-cef.sh" "${CEF_SOURCE_ARGS[@]}" 2>"$CEF_ERROR_LOG")"; then
    if [[ "${CMUX_CEF_ALLOW_DOWNLOAD:-0}" != "1" ]]; then
      echo "embed-cef: framework for $CEF_ARCH is not cached; skipping optional CEF embed (set CMUX_CEF_ALLOW_DOWNLOAD=1 to fetch it)"
      exit 0
    fi
    cat "$CEF_ERROR_LOG" >&2
    exit 1
  fi
  CEF_SOURCES+=("$FRAMEWORK_SOURCE")
done
FRAMEWORK_SOURCE="${CEF_SOURCES[0]}"

APP_FRAMEWORKS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Frameworks"
mkdir -p "$APP_FRAMEWORKS"
HELPER_CACHE_DIR="${DERIVED_FILE_DIR:-$TMPDIR}/cmux-cef-helper"
mkdir -p "$HELPER_CACHE_DIR"

# ditto, not rsync: Apple's tool copies the framework tree faithfully on
# every macOS release. The copy is skipped when the cached source is already
# mirrored (marker matches), because the framework is ~400MB.
#
# The location is not negotiable: Chromium resolves its resources and child
# processes relative to <app>/Contents/Frameworks/Chromium Embedded
# Framework.framework and CHECK-fails at initialize when moved.
DEST="$APP_FRAMEWORKS/Chromium Embedded Framework.framework"
# The marker lives outside the bundle: loose files under Frameworks/ fail
# the app's code signing.
MARKER="$HELPER_CACHE_DIR/.cef-source"
EXPECTED_MARKER="$(printf '%s\n' "${CEF_SOURCES[@]}")"
if [[ ! -d "$DEST" || "$(cat "$MARKER" 2>/dev/null)" != "$EXPECTED_MARKER" \
      || ! -e "$DEST/Versions/Current/Resources/Info.plist" ]]; then
  rm -rf "$DEST" "$APP_FRAMEWORKS/ChromiumEmbedded"
  ditto "$FRAMEWORK_SOURCE" "$DEST"
  printf '%s' "$EXPECTED_MARKER" > "$MARKER"

  # CEF ships separate framework archives per architecture. A universal app
  # must merge every Mach-O inside the versioned framework, not just the main
  # dylib; the GPU/SwiftShader libraries are loaded by child processes too.
  if [[ "${#CEF_SOURCES[@]}" -gt 1 ]]; then
    FRAMEWORK_VERSION="$DEST/Versions/Current"
    while IFS= read -r relative_binary; do
      [[ -n "$relative_binary" ]] || continue
      INPUTS=()
      for source in "${CEF_SOURCES[@]}"; do
        INPUTS+=("$source/Versions/Current/$relative_binary")
      done
      for input in "${INPUTS[@]}"; do
        [[ -f "$input" ]] || {
          echo "embed-cef: missing universal framework binary $input" >&2
          exit 1
        }
      done
      output="$FRAMEWORK_VERSION/$relative_binary"
      temporary="$output.universal"
      lipo -create "${INPUTS[@]}" -output "$temporary"
      mv -f "$temporary" "$output"
    done < <(
      printf '%s\n' "Chromium Embedded Framework"
      find "$FRAMEWORK_VERSION/Libraries" -maxdepth 1 -type f -name '*.dylib' \
        -exec sh -c 'printf "Libraries/%s\\n" "$(basename "$1")"' _ {} \;
      )
  fi
fi

# Compile the helper binary once per toolchain/source change.
HELPER_SOURCE="$SRCROOT/Packages/macOS/CmuxCEF/Helper/helper_main.c"
HELPER_INCLUDES="$SRCROOT/Packages/macOS/CmuxCEF/Sources/CmuxCEFShim/cef"
HELPER_INPUTS=()
for HELPER_ARCH in "${CEF_ARCHES[@]}"; do
  HELPER_INPUT="$HELPER_CACHE_DIR/cmux-cef-helper-$HELPER_ARCH"
  if [[ ! -x "$HELPER_INPUT" || "$HELPER_SOURCE" -nt "$HELPER_INPUT" ]]; then
    xcrun clang -O2 -mmacosx-version-min=14.0 -arch "$HELPER_ARCH" \
      -I"$HELPER_INCLUDES" \
      -Wl,-undefined,dynamic_lookup \
      -o "$HELPER_INPUT" "$HELPER_SOURCE"
  fi
  HELPER_INPUTS+=("$HELPER_INPUT")
done
if [[ "${#HELPER_INPUTS[@]}" -eq 1 ]]; then
  HELPER_BINARY="${HELPER_INPUTS[0]}"
else
  HELPER_BINARY="$HELPER_CACHE_DIR/cmux-cef-helper-universal"
  if [[ ! -x "$HELPER_BINARY" || "$HELPER_SOURCE" -nt "$HELPER_BINARY" ]]; then
    lipo -create "${HELPER_INPUTS[@]}" -output "$HELPER_BINARY.tmp"
    mv -f "$HELPER_BINARY.tmp" "$HELPER_BINARY"
  fi
fi

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"

make_helper() {
  local suffix="$1" idsuffix="$2"
  local name="cmux CEF Helper${suffix}"
  local bundle="$APP_FRAMEWORKS/${name}.app"
  mkdir -p "$bundle/Contents/MacOS"
  cp -f "$HELPER_BINARY" "$bundle/Contents/MacOS/${name}"
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>${name}</string>
  <key>CFBundleIdentifier</key><string>${PRODUCT_BUNDLE_IDENTIFIER}.cef-helper${idsuffix}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
  codesign --force --sign "$SIGN_IDENTITY" "$bundle"
}

make_helper "" ""
make_helper " (GPU)" ".gpu"
make_helper " (Renderer)" ".renderer"
make_helper " (Plugin)" ".plugin"
make_helper " (Alerts)" ".alerts"

# The app's CodeSign step requires every nested framework to be signed.
# Re-signing the ~400MB framework dominates incremental builds, so it is
# skipped while the existing signature still verifies.
if ! codesign --verify "$DEST" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_IDENTITY" "$DEST"
fi
if [[ ! -e "$DEST/Versions/Current/Resources/Info.plist" ]]; then
  echo "embed-cef: framework copy is malformed (no versioned Info.plist)" >&2
  exit 1
fi
echo "embed-cef: framework and helpers embedded"
