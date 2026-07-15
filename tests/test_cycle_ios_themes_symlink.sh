#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/cmux-theme-cycle-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/config/ghostty" "$test_root/dotfiles"
printf 'theme = "Original"\n' > "$test_root/dotfiles/ghostty-config"
ln -s ../../dotfiles/ghostty-config "$test_root/config/ghostty/config"

set +e
XDG_CONFIG_HOME="$test_root/config" \
  "$repo_root/scripts/cycle-ios-themes.sh" \
  --tag missing-theme-test-socket \
  --interval 0 \
  --cycles 1 \
  >/dev/null 2>&1
cycle_status=$?
set -e

if (( cycle_status == 0 )); then
  echo "expected the missing tagged socket to stop the cycle" >&2
  exit 1
fi
if [[ ! -L "$test_root/config/ghostty/config" ]]; then
  echo "theme cycle replaced the Ghostty config symlink" >&2
  exit 1
fi
if [[ "$(cat "$test_root/dotfiles/ghostty-config")" != 'theme = "Original"' ]]; then
  echo "theme cycle did not restore the symlink target contents" >&2
  exit 1
fi
