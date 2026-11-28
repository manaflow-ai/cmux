#!/usr/bin/env bash
# Parse shell scripts with the macOS /bin/bash (3.2) before a job runs them.
#
# Usage: scripts/ci/check-bash32-parse.sh [workflow.yml ...]
#
# Parses every scripts/ci/**/*.sh and scripts/measure/*.sh file, and every
# scripts/**.sh path that a scripts/ci file or a named workflow file mentions. Exits 1 and names each file
# that does not parse.
#
# Why: bash 3.2 rejects some scripts that bash 5 (Linux CI) accepts, and when a
# script has an EXIT trap, bash 3.2 exits 0 on that parse error. nightly-next
# runs 39014131817 and 39014922771 "notarized" without a staple that way, and
# only the syspolicy gate stopped them. CMUX_PARSE_BASH picks another bash.
set -euo pipefail

PARSE_BASH="${CMUX_PARSE_BASH:-/bin/bash}"
ROOT_DIR="${CMUX_PARSE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT_DIR"

echo "Parsing with $PARSE_BASH: $("$PARSE_BASH" -c 'echo "$BASH_VERSION"')"

list="$(mktemp)"
trap 'rm -f "$list"' EXIT
if [ -d scripts/ci ]; then
  # Tracked files only when this is a checkout: a stale untracked file in a
  # reused self-hosted workspace is not this commit's script.
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files 'scripts/ci/*.sh' 'scripts/ci/**/*.sh' >>"$list"
  else
    find scripts/ci -type f -name '*.sh' -print >>"$list"
  fi
  # Scripts that scripts/ci calls by path (for example
  # scripts/verify-app-bundle-channel-metadata.sh from notarize-nightly-dmg.sh).
  grep -rhoE 'scripts/[A-Za-z0-9_./-]+\.sh' scripts/ci >>"$list" || true
fi
# scripts/measure runs on fleet Macs under /bin/bash 3.2 too (cmux-ci steps). A
# script that needs bash 4 on purpose says so on a line of its own:
#   # bash32-parse: skip (WHY)
if [ -d scripts/measure ]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files 'scripts/measure/*.sh' >>"$list"
  else
    find scripts/measure -type f -name '*.sh' -print >>"$list"
  fi
fi
for workflow in "$@"; do
  if [ ! -f "$workflow" ]; then
    echo "::error::workflow file $workflow does not exist" >&2
    exit 1
  fi
  grep -oE 'scripts/[A-Za-z0-9_./-]+\.sh' "$workflow" >>"$list" || true
done

failed=0
checked=0
while IFS= read -r script; do
  [ -n "$script" ] || continue
  if [ ! -f "$script" ]; then
    # A workflow can name a script that only another branch has; the step that
    # runs it fails on its own.
    continue
  fi
  if grep -qE '^# bash32-parse: skip \(.+\)' "$script"; then
    echo "Skipped $script: $(grep -m1 -E '^# bash32-parse: skip' "$script")"
    continue
  fi
  checked=$((checked + 1))
  if ! "$PARSE_BASH" -n "$script"; then
    echo "::error file=$script::does not parse under $PARSE_BASH" >&2
    failed=1
  fi
  # bash 4 builtins parse under 3.2 but fail when run (exit 127): the kit's simulator step died on mapfile from
  # #60888 on. A script named for the Mac runs on its /bin/bash.
  case "$script" in
    *mac*|*Mac*)
      if grep -nE '^[[:space:]]*(mapfile|readarray)[[:space:]]' "$script" >&2; then
        echo "::error file=$script::uses mapfile/readarray, which macOS /bin/bash 3.2 does not have" >&2
        failed=1
      fi
      ;;
  esac
done < <(LC_ALL=C sort -u "$list")

echo "Parsed $checked script(s)"
if [ "$checked" -eq 0 ]; then
  echo "::error::no script to parse under $ROOT_DIR" >&2
  exit 1
fi
exit "$failed"
