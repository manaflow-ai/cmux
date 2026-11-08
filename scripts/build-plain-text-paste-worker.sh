#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <output> [archs]" >&2
  exit 2
fi

output="$1"
archs="${2:-}"
source="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/workers/cmux-paste-text/main.m"
mkdir -p "$(dirname "$output")"

arch_flags=()
for arch in $archs; do
  arch_flags+=( -arch "$arch" )
done

xcrun --sdk macosx clang \
  -fobjc-arc \
  -fmodules \
  -O2 -Wall -Wextra -Werror \
  -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
  "${arch_flags[@]+"${arch_flags[@]}"}" \
  -framework AppKit \
  -framework Foundation \
  -framework UniformTypeIdentifiers \
  "$source" \
  -o "$output"
chmod 755 "$output"

# Debug and universal helpers must be executable before the bundle is sealed.
/usr/bin/codesign --force --sign - --timestamp=none "$output"
