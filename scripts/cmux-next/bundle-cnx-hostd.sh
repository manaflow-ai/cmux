#!/usr/bin/env bash
# Xcode "Bundle cnx-hostd" phase for cmux-next: copies the cmux cnx iPhone
# host into Contents/Resources/bin/cnx-hostd, from CMUX_NEXT_CNX_HOSTD_BIN or
# the cache build-cnx-hostd.sh fills on CI and fleet builds. It never runs Cargo.
#
# A build without it is still a valid build: Settings > Mobile then says
# iPhone connections are not available. Release builds carry it only when
# CMUX_NEXT_CNX_HOSTD_BIN names it (reload.sh sets it on fleet and CI builds,
# universal for Release; the release signing step signs every Mach-O in
# Resources/bin). CMUX_NEXT_REQUIRE_CNX_HOSTD=1 turns a missing
# binary into an error.
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/cnx-hostd"
rm -f "$dest" "$dest.version"

src="${CMUX_NEXT_CNX_HOSTD_BIN:-}"
if [[ "${CONFIGURATION:-Debug}" == Release* && -z "$src" && "${CMUX_NEXT_REQUIRE_CNX_HOSTD:-}" != 1 ]]; then
  echo "cnx-hostd: not bundled in this ${CONFIGURATION} build (CMUX_NEXT_CNX_HOSTD_BIN is unset)"
  exit 0
fi
if [[ -z "$src" ]]; then
  src="$({ "$repo_root/scripts/cmux-next/build-cnx-hostd.sh" --cached-only --print-path; } 2>/dev/null || true)"
fi
if [[ -z "$src" || ! -f "$src" ]]; then
  if [[ "${CMUX_NEXT_REQUIRE_CNX_HOSTD:-}" == 1 ]]; then
    echo "error: no cnx-hostd binary for this build; run scripts/cmux-next/build-cnx-hostd.sh on CI or the fleet" >&2
    exit 1
  fi
  echo "warning: cnx-hostd not bundled (no cached build of this source); iPhone connections are unavailable" >&2
  exit 0
fi
/usr/bin/file -b "$src" | grep -q 'Mach-O' || { echo "error: cnx-hostd source is not a Mach-O executable: $src" >&2; exit 1; }
if command -v lipo >/dev/null 2>&1 && [[ -n "${ARCHS:-}" ]]; then
  actual="$(lipo -archs "$src")"
  for expected in $ARCHS; do
    [[ " $actual " == *" $expected "* ]] || { echo "error: cnx-hostd has '$actual', the app needs '$ARCHS'" >&2; exit 1; }
  done
fi
mkdir -p "$dest_dir"
cp "$src" "$dest"
chmod 755 "$dest"
cp -f "$src.ref" "$dest.version" 2>/dev/null || true
echo "bundled cnx-hostd from $src"
