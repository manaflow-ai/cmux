#!/usr/bin/env bash
# Xcode "Embed app FFI library" phase of the cmux-next target: puts the app FFI
# library (libcmux_app_ffi.dylib, from the pinned CCmuxAppFFI.xcframework that
# scripts/cmux-next/build-app-ffi.sh builds) at
# Contents/Frameworks/libcmux_app_ffi.dylib, where the app's @rpath
# (@executable_path/../Frameworks) finds it at launch. The library the app
# carries there is the one swapped when only FFI crates change
# (scripts/cmux-next/hot-apply.py, part ffi).
#
# The phase reads which library the link used: the app's executable (or, in a
# Debug build, its .debug.dylib) loading @rpath/libcmux_app_ffi.dylib. A pin of
# the old static library loads none, and the phase only removes a copy an
# earlier build left. Xcode's xcframework step copies the library into
# BUILT_PRODUCTS_DIR; a build that linked it with no library there fails here,
# never at the app's first launch.
#
# Signed with the build's identity when the build signs (EXPANDED_CODE_SIGN_IDENTITY,
# with the hardened runtime when the target has it); a build with
# CODE_SIGNING_ALLOWED=NO (the nightly) keeps the library's ad hoc signature and
# scripts/sign-cmux-bundle.sh signs every framework for release.
set -euo pipefail

name=libcmux_app_ffi.dylib
contents="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
dest="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/$name"

links_dylib() {
  local image
  for image in "${TARGET_BUILD_DIR:?}/${EXECUTABLE_PATH:?}" "$contents/MacOS/"*.debug.dylib; do
    [[ -f "$image" ]] || continue
    if xcrun otool -L "$image" | grep -Fq "@rpath/$name "; then
      return 0
    fi
  done
  return 1
}

if ! links_dylib; then
  if [[ -e "$dest" ]]; then
    rm -f "$dest"
    echo "note: the app links the app FFI statically; removed the $name an earlier build left"
  else
    echo "note: the app links the app FFI statically; nothing to embed"
  fi
  exit 0
fi

src="${BUILT_PRODUCTS_DIR:?}/$name"
if [[ ! -f "$src" ]]; then
  echo "error: the app links @rpath/$name, but $src is missing (Xcode copies it there from CCmuxAppFFI.xcframework)" >&2
  exit 1
fi

mkdir -p "$(dirname "$dest")"
if [[ -f "$dest" ]] && cmp -s "$src" "$dest" && [[ "${CODE_SIGNING_ALLOWED:-NO}" != YES ]]; then
  echo "note: $name unchanged"
  exit 0
fi
install -m 755 "$src" "$dest"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES ]]; then
  runtime=()
  [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == YES ]] && runtime=(--options runtime)
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" ${runtime[@]+"${runtime[@]}"} \
    --timestamp=none "$dest"
fi
echo "note: embedded $name ($(xcrun lipo -archs "$dest"))"
