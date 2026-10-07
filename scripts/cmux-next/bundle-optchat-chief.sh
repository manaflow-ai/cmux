#!/usr/bin/env bash
# Xcode "Bundle optchat-chief" phase for cmux-next: copies the OptChat Chief
# brain host into Contents/Resources/bin/optchat-chief, from
# CMUX_NEXT_OPTCHAT_CHIEF_BIN or the commit-addressed cache that
# build-optchat-chief.sh fills on CI and fleet builds. It never runs Cargo.
#
# A build without the binary is still a valid build: Home works and the Chief
# does not answer. Debug builds take the commit-addressed cache. A Release
# build carries it only when CMUX_NEXT_OPTCHAT_CHIEF_BIN names the binary: the
# nightly-next build sets it (its sign step signs every Mach-O in Resources/bin
# with the app's Developer ID and hardened runtime); release and RC builds do
# not, and the app starts it only on DEV and NIGHTLY (HomeBrainHost.swift).
# CMUX_NEXT_REQUIRE_OPTCHAT_CHIEF=1 (fleet reloads, nightly-next) turns a
# missing binary into an error.
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
dest_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
dest="$dest_dir/optchat-chief"
rm -f "$dest" "$dest.version"

src="${CMUX_NEXT_OPTCHAT_CHIEF_BIN:-}"
if [[ "${CONFIGURATION:-Debug}" == Release* && -z "$src" ]]; then
  echo "optchat-chief: not bundled in this ${CONFIGURATION} build (CMUX_NEXT_OPTCHAT_CHIEF_BIN is unset)"
  exit 0
fi
if [[ -z "$src" ]]; then
  src="$({ "$repo_root/scripts/cmux-next/build-optchat-chief.sh" --cached-only --print-path; } 2>/dev/null || true)"
fi
if [[ -z "$src" || ! -f "$src" ]]; then
  if [[ "${CMUX_NEXT_REQUIRE_OPTCHAT_CHIEF:-}" == 1 ]]; then
    echo "error: no optchat-chief binary for this build; run scripts/cmux-next/build-optchat-chief.sh on CI or the fleet" >&2
    exit 1
  fi
  echo "warning: optchat-chief not bundled (no cached build for this commit); the Home Chief will not answer" >&2
  exit 0
fi
/usr/bin/file -b "$src" | grep -q 'Mach-O' || { echo "error: optchat-chief source is not a Mach-O executable: $src" >&2; exit 1; }
if command -v lipo >/dev/null 2>&1 && [[ -n "${ARCHS:-}" ]]; then
  actual="$(lipo -archs "$src")"
  for expected in $ARCHS; do
    [[ " $actual " == *" $expected "* ]] || { echo "error: optchat-chief has '$actual', the app needs '$ARCHS'" >&2; exit 1; }
  done
fi
mkdir -p "$dest_dir"
cp "$src" "$dest"
chmod 755 "$dest"
cp -f "$src.ref" "$dest.version" 2>/dev/null || true
echo "bundled optchat-chief from $src"
