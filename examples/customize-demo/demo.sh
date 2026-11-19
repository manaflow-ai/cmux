#!/usr/bin/env bash
# The customization demo: turns each setup on in order, live, then puts your own setup back.
#
#   examples/customize-demo/demo.sh            # step through every setup, Enter for the next
#   examples/customize-demo/demo.sh --auto 12  # 12 s per setup, no keys (for a recording)
#   examples/customize-demo/demo.sh --list     # the order, nothing changes
#   examples/customize-demo/demo.sh --only glass/clear.json
#   examples/customize-demo/demo.sh reset      # put your setup back (cmux customize discard)
#
# Nothing is kept: every step is a `cmux customize use` preview, and the end (or Ctrl-C) runs
# `cmux customize discard`. CMUX names the CLI (default `cmux`); for a NIGHTLY copy point it at that
# copy's `Contents/Resources/bin/cmux` and set CMUX_BUNDLE_ID to the copy's bundle id.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cli="${CMUX:-cmux}"

# The order of the demo: the app looks first (Claude Code, Codex, studio), then the last demo's
# setups redone, glass, widgets. `steps` drops repeats, so a glob after a named file adds only the rest.
order=(
  looks/claude.json
  looks/codex.json
  looks/studio.json
  looks/*.json
  last-demo/*.json
  glass/*.json
  widgets/*.json
)

steps() {
  local pattern file
  for pattern in "${order[@]}"; do
    for file in "$here"/$pattern; do
      [[ -f "$file" ]] && printf '%s\n' "${file#"$here"/}"
    done
  done | awk '!seen[$0]++'
}

title() {
  # The profile's name, or its file name when it has none.
  local name
  name="$(sed -n 's/^[[:space:]]*"name":[[:space:]]*"\([^"]*\)".*/\1/p' "$here/$1" | head -n 1)"
  printf '%s' "${name:-$1}"
}

reset() {
  "$cli" customize discard >/dev/null 2>&1 || true
}

auto=""
only=""
case "${1:-}" in
  reset) reset; echo "Your setup is back."; exit 0 ;;
  --list) steps; exit 0 ;;
  --auto) auto="${2:?--auto takes seconds}" ;;
  --only) only="${2:?--only takes a file under examples/customize-demo}" ;;
  "") ;;
  *) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac

trap 'reset; echo; echo "Your setup is back."' EXIT INT TERM

if [[ -n "$only" ]]; then
  mapfile -t list < <(printf '%s\n' "$only")
else
  mapfile -t list < <(steps)
fi

n=0
for file in "${list[@]}"; do
  n=$((n + 1))
  printf '\n[%d/%d] %s  (%s)\n' "$n" "${#list[@]}" "$(title "$file")" "$file"
  "$cli" customize use "$here/$file"
  if [[ -n "$auto" ]]; then
    sleep "$auto"
  elif [[ $n -lt ${#list[@]} ]]; then
    read -r -p "Enter for the next one, Ctrl-C to stop " _
  else
    read -r -p "Enter to put your setup back " _
  fi
done
