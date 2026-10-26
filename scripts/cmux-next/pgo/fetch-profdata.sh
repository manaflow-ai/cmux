#!/usr/bin/env bash
# fetch-profdata.sh [--pin FILE] [--source PATH|URL] [--cache DIR]
#
# Prints the absolute path of the cmux-next Swift PGO profile that the pin names, fetched by its sha256 and
# checked against it (plans/cmux-next/chrome-parity/p08-startup.md, section F, task 052). The Release build
# (pgo/release-env.sh) passes that path to Package.swift as CMUX_PGO_PROFDATA, which gives the
# CmuxNext targets -profile-use; it never passes a file whose sha256 differs from the pin.
#
# Chrome does the same with chrome/build/mac-arm.pgo.txt: the checkout names one profile, and
# tools/update_pgo_profiles.py downloads that name from the profile bucket; a build without the file
# builds without PGO (build/config/compiler/pgo/pgo.gni, docs/pgo.md).
#
#   --pin     the sha256 file, `<sha256>  cmux-next.profdata` (default $CMUX_PGO_PIN, else
#             Resources/build/cmux-next.profdata.sha256). 050's run-scenarios.py writes the same file next to
#             a new profile, so an A/B can build with a candidate before 054 pins it:
#             CMUX_NEXT_PGO_USE=1 CMUX_PGO_PIN=DIR/cmux-next.profdata.sha256 CMUX_PGO_SOURCE=DIR/cmux-next.profdata \
#               scripts/cmux-next/check-release-compile.sh
#   --source  where the profile is: a local file or a URL (default $CMUX_PGO_SOURCE, else
#             ${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}/pgo/cmux-next/<sha256>.profdata)
#   --cache   the directory that keeps fetched profiles (default $CMUX_PGO_CACHE_DIR, else
#             ~/Library/Caches/cmux/pgo). The profile lands at <cache>/<sha256>/cmux-next.profdata: a new
#             profile is a new path, so a kept DerivedData compiles again (startup-DESIGN.md section 9).
#
# Exit codes: 0 printed the path; 1 no usable profile (stderr says why; the caller builds without
# -profile-use); 2 usage.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/../../.." && pwd -P)"

usage() {
  sed -n '2,2p' "${BASH_SOURCE[0]}" | sed 's/^# /usage: /' >&2
  exit 2
}

pin="${CMUX_PGO_PIN:-$root/Resources/build/cmux-next.profdata.sha256}"
source="${CMUX_PGO_SOURCE:-}"
cache="${CMUX_PGO_CACHE_DIR:-${HOME:?HOME is not set}/Library/Caches/cmux/pgo}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pin) [[ $# -ge 2 ]] || usage; pin="$2"; shift 2 ;;
    --source) [[ $# -ge 2 ]] || usage; source="$2"; shift 2 ;;
    --cache) [[ $# -ge 2 ]] || usage; cache="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "fetch-profdata: unknown argument: $1" >&2; usage ;;
  esac
done
if [[ "$cache" != /* ]]; then
  echo "fetch-profdata: --cache must be an absolute path, got '$cache'" >&2
  exit 2
fi

no_profile() {
  echo "fetch-profdata: $*; building without -profile-use" >&2
  exit 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

[[ -f "$pin" ]] || no_profile "no pin file at $pin"
line="$(grep -vE '^[[:space:]]*(#|$)' "$pin" | head -n 1 || true)"
[[ -n "$line" ]] || no_profile "no profile is pinned in $pin"
read -r sha name rest <<<"$line"
if [[ ! "$sha" =~ ^[0-9a-f]{64}$ || "${name#\*}" != cmux-next.profdata || -n "$rest" ]]; then
  no_profile "the pin in $pin is not '<sha256>  cmux-next.profdata': '$line'"
fi

dest_dir="$cache/$sha"
dest="$dest_dir/cmux-next.profdata"
if [[ -f "$dest" ]]; then
  if [[ "$(sha256_of "$dest")" == "$sha" ]]; then
    printf '%s\n' "$dest"
    exit 0
  fi
  echo "fetch-profdata: the cached $dest does not match its sha256; fetching it again" >&2
  rm -f "$dest"
fi

if [[ -z "$source" ]]; then
  base="${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}"
  source="${base%/}/pgo/cmux-next/$sha.profdata"
fi

mkdir -p "$dest_dir" || no_profile "cannot create $dest_dir"
tmp="$(mktemp "$dest_dir/.cmux-next.profdata.XXXXXX")" || no_profile "cannot write in $dest_dir"
trap 'rm -f "$tmp"' EXIT
if [[ "$source" == *://* ]]; then
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 600 -o "$tmp" "$source" \
    || no_profile "could not download $source"
else
  cp -f "$source" "$tmp" 2>/dev/null || no_profile "could not read $source"
fi
got="$(sha256_of "$tmp")"
[[ "$got" == "$sha" ]] || no_profile "$source has sha256 $got, the pin names $sha"
mv -f "$tmp" "$dest"
printf '%s\n' "$dest"
