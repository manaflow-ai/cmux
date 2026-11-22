#!/usr/bin/env bash
# Gives a CI job its own copy of the bun that webviews/package.json pins
# (devEngines.packageManager), first on GITHUB_PATH.
#
# The minis share ~/.bun between their runner instances, and other workflows
# (ci-macos.yml, ci-guards.yml) install a different bun there. setup-bun only
# checks ~/.bun/bin/bun once, so a concurrent job could swap the binary under a
# running cmux-next job (#18124: setup-bun saw 1.4.2, the web bundle build saw
# 1.3.6). Run this right after setup-bun: it copies that bun into
# $RUNNER_TEMP, or, when the shared one is already another version, downloads
# the pinned release and checks it against the release's SHASUMS256.txt.
#
# CMUX_BUN_RELEASE_BASE overrides https://github.com/oven-sh/bun/releases/download
# (tests serve a release from file://).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
want="$(python3 -c 'import json, sys; m = (json.load(open(sys.argv[1])).get("devEngines") or {}).get("packageManager") or {}; print(m.get("version", "") if m.get("name") == "bun" else "")' "$root/webviews/package.json")"
[[ -n "$want" ]] || { echo "error: webviews/package.json pins no bun (devEngines.packageManager)" >&2; exit 1; }

dir="$RUNNER_TEMP/private-bun"
rm -rf "$dir"
mkdir -p "$dir"
shared="$(command -v bun 2>/dev/null || true)"
source="$shared"
if [[ -n "$shared" ]]; then
  cp "$shared" "$dir/bun.tmp"
  mv -f "$dir/bun.tmp" "$dir/bun"
fi

if [[ ! -x "$dir/bun" || "$("$dir/bun" --version 2>/dev/null || true)" != "$want" ]]; then
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=darwin-aarch64 ;;
    Darwin-x86_64) platform=darwin-x64 ;;
    Linux-x86_64) platform=linux-x64 ;;
    Linux-aarch64 | Linux-arm64) platform=linux-aarch64 ;;
    *) echo "error: no bun release for $(uname -s) $(uname -m)" >&2; exit 1 ;;
  esac
  echo "the shared bun ${shared:-(none)} is not bun $want; downloading the release" >&2
  base="${CMUX_BUN_RELEASE_BASE:-https://github.com/oven-sh/bun/releases/download}/bun-v$want"
  work="$dir/download"
  mkdir -p "$work"
  curl -fsSL --retry 3 -o "$work/bun-$platform.zip" "$base/bun-$platform.zip"
  curl -fsSL --retry 3 -o "$work/SHASUMS256.txt" "$base/SHASUMS256.txt"
  expected="$(awk -v f="bun-$platform.zip" '$2 == f { print $1 }' "$work/SHASUMS256.txt")"
  actual="$(shasum -a 256 "$work/bun-$platform.zip" | awk '{ print $1 }')"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    echo "error: bun-$platform.zip of bun $want has sha256 $actual; SHASUMS256.txt lists ${expected:-nothing}" >&2
    exit 1
  fi
  unzip -q -o "$work/bun-$platform.zip" -d "$work"
  mv -f "$work/bun-$platform/bun" "$dir/bun"
  rm -rf "$work"
  source="the bun-v$want release"
fi

have="$("$dir/bun" --version)"
[[ "$have" == "$want" ]] || { echo "error: the private bun is $have, not $want" >&2; exit 1; }
ln -sf bun "$dir/bunx"
echo "$dir" >> "$GITHUB_PATH"
echo "bun $want for this job: $dir/bun (from $source)"
