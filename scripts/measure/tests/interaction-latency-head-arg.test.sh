#!/usr/bin/env bash
# interaction-latency-linux.sh refuses a bad argument before it installs anything (exit 2), and head= takes only a
# full 40-hex sha: it is fetched and checked out into a worktree, so a short or named ref would bench a moving tree.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/interaction-latency-linux.sh"

refuses() {
  local want="$1" err status
  shift
  set +e
  err="$(bash "$script" "$@" 2>&1 >/dev/null)"
  status=$?
  set -e
  [[ "$status" == 2 ]] || { echo "interaction-latency-linux $*: exit $status, want 2 ($err)" >&2; exit 1; }
  [[ "$err" == *"$want"* ]] || { echo "interaction-latency-linux $*: said '$err', want '$want'" >&2; exit 1; }
}

refuses "usage: interaction-latency-linux.sh interactions=KEY[,KEY...] [head=SHA]"
refuses "unknown argument bogus=1" interactions=composer_typing bogus=1
refuses "head= takes a full 40-hex commit sha, not 435816af" interactions=composer_typing head=435816af
refuses "head= takes a full 40-hex commit sha, not main" interactions=composer_typing head=main
echo "PASS interaction-latency-head-arg"
