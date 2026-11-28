#!/usr/bin/env bash
# Prints what dyld_info -exports looks like under each installed Xcode, on a Swift dylib.
set -u
lib=/usr/lib/swift/libswiftCore.dylib
[[ -e "$lib" ]] || lib=$(ls /Applications/Xcode_27.2.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx/libswiftCore.dylib 2>/dev/null)
for app in /Applications/Xcode_26.6.app /Applications/Xcode_27.2.app; do
  [[ -d "$app" ]] || { echo "== $app absent"; continue; }
  export DEVELOPER_DIR="$app/Contents/Developer"
  echo "== $app: $(xcrun --find dyld_info) $(xcrun dyld_info -version 2>&1 | head -1)"
  xcrun dyld_info -exports "$lib" 2>&1 | head -8 | cut -c1-200
  echo "-- count _\$s: $(xcrun dyld_info -exports "$lib" 2>/dev/null | grep -cE '_\$s')  count \$s: $(xcrun dyld_info -exports "$lib" 2>/dev/null | grep -cE '\$s')"
  xcrun dyld_info -help 2>&1 | grep -i -E 'demangl|export|mangl' | head -8
done
