#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
script="$root/scripts/cmux-next/build-mobile-host.sh"
inputs="$(sed -n 's/^inputs=(//p; s/^  //p' "$script" | tr -d ')' | tr '\n' ' ')"
for path in \
  cmux-next-ios/rust \
  cmux-tui/crates/cmux-wg \
  cmux-tui/crates/cmux-transport \
  cmux-tui/crates/cmux-rd-proto \
  cmux-tui/crates/cmux-rd-core \
  cmux-tui/crates/cmux-rd-engine \
  cmux-tui/crates/cmux-rd-ffi \
  cmux-tui/Cargo.toml; do
  [[ " $inputs " == *" $path "* ]] || { echo "missing mobile-host cache input: $path" >&2; exit 1; }
done
echo "mobile-host cache input set covers remote-desktop path crates"
