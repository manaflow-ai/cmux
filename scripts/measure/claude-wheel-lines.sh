#!/usr/bin/env bash
# How many transcript lines one SGR wheel report scrolls in Claude Code's full-screen renderer
# (CLAUDE_CODE_NO_FLICKER=1), per Claude Code version, for wheel reports spaced like a phone's drag.
# Evidence only (branch ios-tui-scroll-bisect). Each version is downloaded from the official release
# bucket and checked against its manifest checksum, then run in a PTY on a scratch HOME and config
# dir (a dummy API key, no network calls beyond startup), resuming a synthetic transcript of
# numbered lines. A vendored pyte emulates the screen; the top numbered line before and after each
# wheel pattern is the scroll.
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/claude-wheel-lines.sh --ref SHA [--arg=versions=2.1.322,2.1.325]
# Output: CCWHEEL lines.
set -euo pipefail
versions="2.1.321,2.1.322,2.1.323,2.1.325"
for arg in "$@"; do
  case "$arg" in
    versions=*) versions="${arg#versions=}" ;;
    *) echo "claude-wheel-lines.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d /tmp/ccwheel.XXXXXX)"
trap 'rm -rf "$work"' EXIT
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64 ;;
  Darwin-x86_64) platform=darwin-x64 ;;
  Linux-x86_64) platform=linux-x64 ;;
  Linux-aarch64) platform=linux-arm64 ;;
  *) echo "unsupported host"; exit 2 ;;
esac
IFS=, read -r -a list <<<"$versions"
for v in "${list[@]}"; do
  base="https://downloads.claude.ai/claude-code-releases/$v"
  sum="$(curl -fsSL "$base/manifest.json" | python3 -I -c "import json,sys; print(json.load(sys.stdin)['platforms']['$platform']['checksum'])")"
  curl -fsSL -o "$work/claude-$v" "$base/$platform/claude"
  got="$(shasum -a 256 "$work/claude-$v" | cut -d' ' -f1)"
  if [[ "$got" != "$sum" ]]; then echo "CCWHEEL version=$v checksum mismatch"; exit 1; fi
  chmod +x "$work/claude-$v"
  echo "CCWHEEL version=$v sha256=$got platform=$platform"
done
for v in "${list[@]}"; do
  python3 -I "$here/claude_wheel_lines.py" "$work/claude-$v" "$v" "$here/vendor" || echo "CCWHEEL version=$v harness-failed=$?"
done
