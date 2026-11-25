#!/usr/bin/env bash
# mobile-host-fallback.sh ARCHS OUT: when this commit's cmux-mobile-host (the iPhone host,
# built from cmux-next-ios/rust) does not compile, put the newest earlier build of it at OUT
# so the Mac NIGHTLY still publishes (Leo, 11-25: "build broke on an iOS change that left a
# field out of the phone link code are we able to decouple"). Runs 45551813915 and
# 45556730650 failed the whole Mac NIGHTLY on `missing field overlay` in cmux-mobile-link.
#
# Sources, first that has one for ARCHS:
#   1. this Mac's build-mobile-host.sh cache (CMUX_NEXT_MOBILE_HOST_CACHE, default
#      cmux-next-ios/rust/target/hosted/cmux-mobile-host): the newest SOURCE_KEY/ARCH_KEY.
#   2. the published NIGHTLY: the first DMG in CMUX_MOBILE_HOST_FALLBACK_APPCAST
#      (default the nightly-next arm64 feed), Contents/Resources/bin/cmux-mobile-host.
# The copy is re-signed with the app's identity like every Mach-O in Resources/bin
# (sign-cmux-bundle-helpers.sh signs with --force). OUT.ref says where it came from.
# Exit 1 when neither has one: the caller then fails as it did before.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 ARCHS OUT" >&2; exit 2; }
archs="$1"; out="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
arch_key="$(tr ' ' '\n' <<<"$archs" | sed '/^$/d' | sort -u | paste -sd- -)"
mkdir -p "$(dirname "$out")"

has_archs() {
  local bin="$1" have a
  [[ -f "$bin" ]] || return 1
  /usr/bin/file -b "$bin" | grep -q 'Mach-O' || return 1
  command -v lipo >/dev/null 2>&1 || return 0
  have=" $(lipo -archs "$bin") "
  for a in $archs; do [[ "$have" == *" $a "* ]] || return 1; done
}

# 1. this Mac's cache, newest first.
cache_root="${CMUX_NEXT_MOBILE_HOST_CACHE:-$repo_root/cmux-next-ios/rust/target/hosted/cmux-mobile-host}"
if [[ -d "$cache_root" ]]; then
  # shellcheck disable=SC2012 # the names are hex source keys and fixed arch keys; ls -t orders by age
  while IFS= read -r bin; do
    [[ -n "$bin" ]] || continue
    if has_archs "$bin"; then
      cp -f "$bin" "$out"; chmod 755 "$out"
      { echo "fallback=cache"; echo "path=$bin"; cat "$bin.ref" 2>/dev/null || true; } > "$out.ref"
      echo "cmux-mobile-host fallback: this Mac's cached build $bin"
      exit 0
    fi
  done < <(ls -t "$cache_root"/*/"$arch_key"/cmux-mobile-host 2>/dev/null || true)
fi

# 2. the published NIGHTLY.
appcast="${CMUX_MOBILE_HOST_FALLBACK_APPCAST:-https://files-next.cmux.com/nightly-next/appcast-$arch_key.xml}"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mobile-host-fallback.XXXXXX")"
mnt="$work/mnt"
cleanup() {
  if [[ -d "$mnt" ]]; then hdiutil detach -quiet -force "$mnt" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
curl -fsSL --retry 4 --retry-all-errors --max-time 60 "$appcast" -o "$work/appcast.xml" \
  || { echo "cmux-mobile-host fallback: no cache and the feed $appcast did not load" >&2; exit 1; }
dmg_url="$(grep -oE '<enclosure url="[^"]+\.dmg"' "$work/appcast.xml" | head -1 | sed -E 's/.*url="([^"]+)"/\1/' || true)"
[[ -n "$dmg_url" ]] || { echo "cmux-mobile-host fallback: no DMG in $appcast" >&2; exit 1; }
curl -fsSL --retry 4 --retry-all-errors --max-time 900 "$dmg_url" -o "$work/app.dmg" \
  || { echo "cmux-mobile-host fallback: download of $dmg_url failed" >&2; exit 1; }
mkdir -p "$mnt"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$work/app.dmg"
bin="$(find "$mnt" -maxdepth 5 -path '*.app/Contents/Resources/bin/cmux-mobile-host' -print -quit 2>/dev/null || true)"
has_archs "$bin" || { echo "cmux-mobile-host fallback: $dmg_url has no cmux-mobile-host for $archs" >&2; exit 1; }
cp -f "$bin" "$out"; chmod 755 "$out"
{ echo "fallback=published"; echo "dmg=$dmg_url"; cat "$(dirname "$bin")/cmux-mobile-host.version" 2>/dev/null || true; } > "$out.ref"
echo "cmux-mobile-host fallback: the published NIGHTLY's copy from $dmg_url"
