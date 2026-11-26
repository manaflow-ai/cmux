#!/usr/bin/env bash
# mobile-host-fallback.sh ARCHS OUT: when this commit's cmux-mobile-host (the iPhone host,
# built from cmux-next-ios/rust) does not compile and this Mac has no earlier build of it
# (last-good-mobile-host.sh found none: a fresh runner), put the published NIGHTLY's copy at OUT
# so the Mac NIGHTLY still publishes with iPhone connections (Leo, 11-25: "build broke on an iOS change that left a
# field out of the phone link code are we able to decouple"). Runs 45551813915 and
# 45556730650 failed the whole Mac NIGHTLY on `missing field overlay` in cmux-mobile-link.
#
# Source: the first DMG in CMUX_MOBILE_HOST_FALLBACK_APPCAST (default the nightly-next feed for
# ARCHS), Contents/Resources/bin/cmux-mobile-host.
# The copy is re-signed with the app's identity like every Mach-O in Resources/bin
# (sign-cmux-bundle-helpers.sh signs with --force). OUT.ref says where it came from.
# Exit 1 when it has none: the caller then ships without iPhone connections and says so.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 ARCHS OUT" >&2; exit 2; }
archs="$1"; out="$2"
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

# The published NIGHTLY.
appcast="${CMUX_MOBILE_HOST_FALLBACK_APPCAST:-https://files-next.cmux.com/nightly-next/appcast-$arch_key.xml}"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mobile-host-fallback.XXXXXX")"
mnt="$work/mnt"
cleanup() {
  if [[ -d "$mnt" ]]; then hdiutil detach -quiet -force "$mnt" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
curl -fsSL --retry 4 --retry-all-errors --max-time 60 "$appcast" -o "$work/appcast.xml" \
  || { echo "cmux-mobile-host fallback: the feed $appcast did not load" >&2; exit 1; }
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
