#!/usr/bin/env bash
# Fetch a pinned, checksum-verified XcodeGen into a caller's directory and print the binary path.
#
#   fetch-xcodegen.sh VERSION SHA256 DEST_DIR
#
# GitHub answers the fleet Macs' anonymous release downloads with 403 (hq#27705: retrying does not
# help), so one helper owns the fetch for every iOS script. Order:
#   1. the per-host cache ${CMUX_CI_CACHE:-$HOME/Library/Caches/cmux-ci}/xcodegen/VERSION/xcodegen.zip
#      (kept only after its sha256 matches), so a host downloads at most once;
#   2. curl with "Authorization: Bearer $GITHUB_TOKEN" (or $GH_TOKEN) when either is set;
#   3. gh release download, when gh is on PATH and authed;
#   4. anonymous curl.
# The sha256 is always verified. The zip is unpacked into DEST_DIR (the binary needs ../share/xcodegen
# beside it); stdout is DEST_DIR/xcodegen/bin/xcodegen, diagnostics go to stderr.
set -euo pipefail

if [[ $# -ne 3 ]]; then echo "usage: fetch-xcodegen.sh VERSION SHA256 DEST_DIR" >&2; exit 2; fi
version="$1" want="$2" dest="$3"
cache_dir="${CMUX_CI_CACHE:-$HOME/Library/Caches/cmux-ci}/xcodegen/$version"
cached="$cache_dir/xcodegen.zip"
url="https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"

sha_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }

mkdir -p "$dest"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fetch-xcodegen.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
zip="$tmp/xcodegen.zip"

have=""
if [[ -f "$cached" && "$(sha_of "$cached")" == "$want" ]]; then
  cp "$cached" "$zip"; have=1
  echo "fetch-xcodegen: $version from cache $cached" >&2
fi

if [[ -z "$have" ]]; then
  token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$token" ]]; then
    curl -fsSL --retry 3 --retry-delay 2 -H "Authorization: Bearer $token" -o "$zip" "$url" 2>/dev/null &&
      have=1 || echo "fetch-xcodegen: authenticated curl failed" >&2
  fi
  if [[ -z "$have" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release download --repo yonaskolb/XcodeGen "$version" -p xcodegen.zip -O "$zip" --clobber >&2 &&
      have=1 || echo "fetch-xcodegen: gh release download failed" >&2
  fi
  if [[ -z "$have" ]]; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$zip" "$url" &&
      have=1 || { echo "error: could not download xcodegen $version (set GITHUB_TOKEN or GH_TOKEN, or log gh in)" >&2; exit 3; }
  fi
  got="$(sha_of "$zip")"
  [[ "$got" == "$want" ]] ||
    { echo "error: xcodegen $version zip has sha256 $got, expected $want" >&2; exit 3; }
  mkdir -p "$cache_dir" && cp "$zip" "$cached.$$" && mv "$cached.$$" "$cached" ||
    echo "fetch-xcodegen: could not cache in $cache_dir" >&2
fi

unzip -q -o "$zip" -d "$dest"
bin="$dest/xcodegen/bin/xcodegen"
[[ -x "$bin" ]] || { echo "error: no xcodegen binary in the $version zip" >&2; exit 3; }
echo "$bin"
