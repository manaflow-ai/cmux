#!/usr/bin/env bash
# Xcode "Bundle cnx-hostd" phase for cmux-next: copies the cmux cnx iPhone
# host into Contents/Resources/bin/cnx-hostd, from CMUX_NEXT_CNX_HOSTD_BIN or
# the cache build-cnx-hostd.sh fills on CI and fleet builds. It never runs Cargo.
#
# Release builds always carry it, built from this same source: a Release build
# without it, or with a binary whose .ref names another source key, fails here
# (fleet linux-pool and Mac builds once shipped Release apps with no cnx-hostd,
# and the phone could not connect to them). reload.sh and CI hand it over in
# CMUX_NEXT_CNX_HOSTD_BIN (universal for Release; the release signing step
# signs every Mach-O in Resources/bin). CMUX_NEXT_CNX_HOSTD_OPTIONAL=1 is the
# one explicit opt-out, for a Release build that must not carry the host.
#
# Debug builds without it are still valid builds: Settings > Mobile then says
# iPhone connections are not available. CMUX_NEXT_REQUIRE_CNX_HOSTD=1 turns a
# missing binary into an error there too.
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/cnx-hostd"
rm -f "$dest" "$dest.version"
build_script="$repo_root/scripts/cmux-next/build-cnx-hostd.sh"

release=0
[[ "${CONFIGURATION:-Debug}" == Release* ]] && release=1
required=0
if [[ "${CMUX_NEXT_REQUIRE_CNX_HOSTD:-}" == 1 ]]; then required=1; fi
if [[ "$release" -eq 1 && "${CMUX_NEXT_CNX_HOSTD_OPTIONAL:-}" != 1 ]]; then required=1; fi
if [[ "$release" -eq 1 && "$required" -eq 0 ]]; then
  echo "cnx-hostd: not bundled in this ${CONFIGURATION} build (CMUX_NEXT_CNX_HOSTD_OPTIONAL=1)"
  exit 0
fi

src="${CMUX_NEXT_CNX_HOSTD_BIN:-}"
if [[ -z "$src" ]]; then
  src="$({ "$build_script" --cached-only --print-path; } 2>/dev/null || true)"
fi
if [[ -z "$src" || ! -f "$src" ]]; then
  if [[ "$required" -eq 1 ]]; then
    echo "error: no cnx-hostd binary for this ${CONFIGURATION:-Debug} build (CMUX_NEXT_CNX_HOSTD_BIN='${CMUX_NEXT_CNX_HOSTD_BIN:-}', no cached build of this source). A Release cmux-next app must bundle cnx-hostd: run scripts/cmux-next/build-cnx-hostd.sh on CI, the fleet or nx-remote, or set CMUX_NEXT_CNX_HOSTD_OPTIONAL=1 to ship an app the phone cannot reach" >&2
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

# Same source: the .ref build-cnx-hostd.sh writes names the source key it was
# built from; it must be this checkout's key.
want_key="$("$build_script" --print-key 2>/dev/null || true)"
have_key="$(sed -n 's/^key=//p' "$src.ref" 2>/dev/null | head -1)"
if [[ -z "$have_key" || -z "$want_key" || "$have_key" != "$want_key" ]]; then
  msg="cnx-hostd at $src was built from source key '${have_key:-unknown}', this checkout is '${want_key:-unknown}'"
  if [[ "$required" -eq 1 ]]; then
    echo "error: $msg; rebuild it with scripts/cmux-next/build-cnx-hostd.sh" >&2
    exit 1
  fi
  echo "warning: $msg" >&2
fi

mkdir -p "$dest_dir"
cp "$src" "$dest"
chmod 755 "$dest"
cp -f "$src.ref" "$dest.version" 2>/dev/null || true
echo "bundled cnx-hostd from $src (source key ${have_key:-unknown})"
