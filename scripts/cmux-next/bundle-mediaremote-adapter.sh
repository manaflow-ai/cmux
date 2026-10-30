#!/usr/bin/env bash
# Xcode "Bundle MediaRemote adapter" phase of the cmux-next target: compiles
# vendor/mediaremote-adapter (ungive/mediaremote-adapter, BSD-3-Clause) the way
# its CMakeLists.txt does and puts it where MediaRemoteAdapterProcess.bundled()
# finds it:
#
#   Contents/Frameworks/MediaRemoteAdapter.framework        loaded by /usr/bin/perl, not linked
#   Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl
#
# The Now Playing card reads other apps' tracks through it (Spotify, Music):
# since macOS 15.4 only Apple-signed processes may read MediaRemote, so the app
# runs `/usr/bin/perl mediaremote-adapter.pl <framework> stream`. One slice per
# arch in $ARCHS, built for $MACOSX_DEPLOYMENT_TARGET with symbols visible (the
# script calls the framework's adapter_* functions by name). Skipped when the
# sources, archs and target are unchanged since the last build. Signed with the
# build's identity (EXPANDED_CODE_SIGN_IDENTITY, ad hoc when empty);
# scripts/sign-cmux-bundle.sh signs every framework again for release.
set -euo pipefail

src="${SRCROOT:?}/vendor/mediaremote-adapter"
app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
framework="$app/Contents/Frameworks/MediaRemoteAdapter.framework"
resources="$app/Contents/Resources/MediaRemoteAdapter"
work="${TARGET_TEMP_DIR:-${DERIVED_FILE_DIR:?}}/mediaremote-adapter"
minimum="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
read -r -a archs <<< "${ARCHS:-arm64}"

sources=(
  src/adapter/env.m src/adapter/get.m src/adapter/globals.m src/adapter/keys.m
  src/adapter/now_playing.m src/adapter/repeat.m src/adapter/seek.m src/adapter/send.m
  src/adapter/shuffle.m src/adapter/speed.m src/adapter/stream.m src/adapter/test.m
  src/private/MediaRemote.m src/utility/Debounce.m src/utility/helpers.m
)

mkdir -p "$work"
stamp="$work/stamp"
key="$( { echo "${archs[*]} $minimum ${EXPANDED_CODE_SIGN_IDENTITY:--}"; (cd "$src" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256); } | shasum -a 256 | cut -d' ' -f1)"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$key" && -f "$framework/Versions/A/MediaRemoteAdapter" \
      && -f "$resources/mediaremote-adapter.pl" ]]; then
  echo "note: MediaRemote adapter unchanged"
  exit 0
fi
rm -f "$stamp"

slices=()
for arch in "${archs[@]}"; do
  out="$work/MediaRemoteAdapter-$arch"
  xcrun clang -arch "$arch" -mmacosx-version-min="$minimum" -dynamiclib -O2 -fobjc-arc -fvisibility=default \
    -I"$src/include" -I"$src/src" \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    "${sources[@]/#/$src/}" -o "$out"
  slices+=("$out")
done

rm -rf "$framework"
mkdir -p "$framework/Versions/A/Resources"
xcrun lipo -create "${slices[@]}" -output "$framework/Versions/A/MediaRemoteAdapter"
cat > "$framework/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundleIdentifier</key><string>com.cmuxterm.MediaRemoteAdapter</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
</dict>
</plist>
PLIST
ln -sfh A "$framework/Versions/Current"
ln -sfh Versions/Current/MediaRemoteAdapter "$framework/MediaRemoteAdapter"
ln -sfh Versions/Current/Resources "$framework/Resources"

mkdir -p "$resources"
cp "$src/bin/mediaremote-adapter.pl" "$resources/mediaremote-adapter.pl"
cp "$src/LICENSE" "$resources/LICENSE"

/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$framework"
echo "$key" > "$stamp"
echo "note: bundled the MediaRemote adapter (${archs[*]}, macOS $minimum)"
