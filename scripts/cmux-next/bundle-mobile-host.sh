#!/usr/bin/env bash
# Xcode "Bundle cmux-mobile-host" phase for cmux-next: copies the cmux mobile iPhone
# host into Contents/Resources/bin/cmux-mobile-host, from CMUX_NEXT_MOBILE_HOST_BIN or
# the cache build-mobile-host.sh fills on CI and fleet builds. It never runs Cargo.
#
# A build without it is still a valid build: Settings > Mobile then says
# iPhone connections are not available. Release builds carry it only when
# CMUX_NEXT_MOBILE_HOST_BIN names it (reload.sh sets it on fleet and CI builds,
# universal for Release; the release signing step signs every Mach-O in
# Resources/bin). CMUX_NEXT_REQUIRE_MOBILE_HOST=1 turns a missing
# binary into an error.
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/cmux-mobile-host"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/bundle-mobile-host.stamp"
on_exit() {
  status=$?
  if (( status == 0 )); then
    mkdir -p "$(dirname "$stamp")"
    printf 'completed\n' > "$stamp"
  fi
  exit "$status"
}
trap on_exit EXIT
rm -f "$stamp"
rm -f "$dest" "$dest.version"

src="${CMUX_NEXT_MOBILE_HOST_BIN:-}"
if [[ "${CONFIGURATION:-Debug}" == Release* && -z "$src" && "${CMUX_NEXT_REQUIRE_MOBILE_HOST:-}" != 1 ]]; then
  echo "cmux-mobile-host: not bundled in this ${CONFIGURATION} build (CMUX_NEXT_MOBILE_HOST_BIN is unset)"
  exit 0
fi
if [[ -z "$src" ]]; then
  src="$({ "$repo_root/scripts/cmux-next/build-mobile-host.sh" --cached-only --print-path; } 2>/dev/null || true)"
fi
if [[ -z "$src" || ! -f "$src" ]]; then
  if [[ "${CMUX_NEXT_REQUIRE_MOBILE_HOST:-}" == 1 ]]; then
    echo "error: no cmux-mobile-host binary for this build; run scripts/cmux-next/build-mobile-host.sh on CI or the fleet" >&2
    exit 1
  fi
  echo "warning: cmux-mobile-host not bundled (no cached build of this source); iPhone connections are unavailable" >&2
  exit 0
fi
/usr/bin/file -b "$src" | grep -q 'Mach-O' || { echo "error: cmux-mobile-host source is not a Mach-O executable: $src" >&2; exit 1; }
if command -v lipo >/dev/null 2>&1 && [[ -n "${ARCHS:-}" ]]; then
  actual="$(lipo -archs "$src")"
  for expected in $ARCHS; do
    [[ " $actual " == *" $expected "* ]] || { echo "error: cmux-mobile-host has '$actual', the app needs '$ARCHS'" >&2; exit 1; }
  done
fi
mkdir -p "$dest_dir"
cp "$src" "$dest"
chmod 755 "$dest"
cp -f "$src.ref" "$dest.version" 2>/dev/null || true
echo "bundled cmux-mobile-host from $src"
