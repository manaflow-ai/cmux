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

mkdir -p "$test_root/failing-bin" "$test_root/failure-config/ghostty/themes"
printf 'theme = "Original"\n' > "$test_root/failure-config/ghostty/config"
printf 'background = #123456\n' > "$test_root/failure-config/ghostty/themes/cmux iOS Theme Cycle"
cat > "$test_root/failing-bin/cat" <<'EOF'
#!/usr/bin/env bash
IFS= read -r first_line || true
printf '%s\n' "$first_line"
exit 1
EOF
chmod +x "$test_root/failing-bin/cat"

set +e
PATH="$test_root/failing-bin:$PATH" \
  XDG_CONFIG_HOME="$test_root/failure-config" \
  "$repo_root/scripts/cycle-ios-themes.sh" \
  --tag setup-failure-test \
  --interval 0 \
  --cycles 1 \
  >/dev/null 2>&1
failure_status=$?
set -e

if (( failure_status == 0 )); then
  echo "expected the partial custom theme write to fail" >&2
  exit 1
fi
if [[ "$(/bin/cat "$test_root/failure-config/ghostty/config")" != 'theme = "Original"' ]]; then
  echo "setup failure changed the Ghostty config" >&2
  exit 1
fi
if [[ "$(/bin/cat "$test_root/failure-config/ghostty/themes/cmux iOS Theme Cycle")" != 'background = #123456' ]]; then
  echo "setup failure did not restore the existing custom theme" >&2
  exit 1
fi
