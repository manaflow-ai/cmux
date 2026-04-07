#!/usr/bin/env bash
set -euo pipefail

input=""

cleanup() {
  printf '\033[?1049l\033[?25h'
}

render() {
  local size
  size="$(stty size 2>/dev/null || echo '0 0')"
  printf '\033[H\033[2J'
  printf 'FAKE-TUI %s\n' "$size"
  printf 'INPUT %s\n' "$input"
  printf 'Press q to quit\n'
}

trap cleanup EXIT
trap render WINCH

printf '\033[?1049h\033[?25l'
render

while IFS= read -r -n 1 ch; do
  case "$ch" in
    q)
      break
      ;;
    $'\r'|$'\n')
      ;;
    *)
      input="${input}${ch}"
      ;;
  esac
  render
done
