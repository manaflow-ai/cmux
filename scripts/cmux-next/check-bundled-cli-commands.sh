#!/usr/bin/env bash
# Fails when a CLI command in a built cmux-next bundle cannot run from the
# bundle alone: a subcommand that hands off to a binary the bundle lacks
# (`cmux vm` once spawned a `cmux-vm` no bundle shipped: "cmux-vm not found in
# PATH"). Each line of scripts/cmux-next/bundled-cli-commands.txt is a
# command's arguments; the bundled bin/cmux runs it with an empty environment
# and PATH=/usr/bin:/bin, so nothing outside the bundle can stand in. A
# nonzero exit, or output naming a missing program, fails the check.
# Usage: scripts/cmux-next/check-bundled-cli-commands.sh <path to cmux.app>
set -euo pipefail
app="${1:?usage: check-bundled-cli-commands.sh <app bundle>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
list="$root/scripts/cmux-next/bundled-cli-commands.txt"
cli="$app/Contents/Resources/bin/cmux"
[ -x "$cli" ] || { echo "check-bundled-cli-commands: $cli is missing" >&2; exit 1; }
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
failed=0
checked=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  read -r -a words <<<"$line"
  checked=$((checked + 1))
  set +e
  out="$(env -i HOME="$scratch" PATH=/usr/bin:/bin "$cli" "${words[@]}" 2>&1 </dev/null)"
  status=$?
  set -e
  if [ "$status" -ne 0 ] || grep -Eqi 'not found in PATH|cannot start|No such file or directory' <<<"$out"; then
    echo "bundled cli: \`cmux $line\` failed (exit $status):" >&2
    sed -n '1,5p' <<<"$out" >&2
    failed=1
  else
    echo "bundled cli: cmux $line ok"
  fi
done <"$list"
[ "$checked" -gt 0 ] || { echo "check-bundled-cli-commands: $list lists no commands" >&2; exit 1; }
exit "$failed"
