#!/usr/bin/env bash
# pin-cmux-tui.sh fetch in CI: when the cmux-tui artifacts runs for the
# publisher commit (CMUX_TUI_TREE_PUBLISHER_SHA) were cancelled, ended without
# publishing the tree (superseded), or do not exist, the wait fails fast with
# a clear reason instead of polling for the full CMUX_TUI_TREE_WAIT_SECONDS.
# An active run, or an API that cannot be read, keeps the old bounded wait.
# No network: the CDN base is unreachable and the GitHub API is a file:// tree.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

git_q init "$TMP/src"
mkdir -p "$TMP/src/cmux-tui" "$TMP/src/scripts/cmux-next"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$TMP/src/scripts/cmux-next/"
echo one > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m one
git_q -C "$TMP/src" update-index --add --cacheinfo 160000,"$(git -C "$TMP/src" rev-parse HEAD)",ghostty
git_q -C "$TMP/src" commit -m gitlink
mkdir "$TMP/src/ghostty" # an uninitialized submodule, as on a CI checkout
sha=$(git -C "$TMP/src" rev-parse HEAD)

runs_dir="$TMP/api/repos/o/r/actions/workflows/cmux-tui-artifacts.yml"
mkdir -p "$runs_dir"
set_runs() { printf '%s\n' "$1" > "$runs_dir/runs"; }

# fetch <wait seconds> -> sets out, status, took
fetch() {
  local started
  started=$(date +%s)
  status=0
  out=$(cd "$TMP/src" && env -u CI_JOB_DIR GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_SHA="$sha" \
    GITHUB_REPOSITORY=o/r GITHUB_API_URL="file://$TMP/api" GH_TOKEN=test-token \
    CMUX_TUI_TREE_PUBLISHER_SHA="$sha" CMUX_TUI_PIN_BASE=https://127.0.0.1:9/cmux-tui \
    CMUX_TUI_TREE_WAIT_SECONDS="$1" CMUX_TUI_TREE_POLL_SECONDS=1 CMUX_TUI_TREE_RUN_CHECK_SECONDS=1 \
    bash scripts/cmux-next/pin-cmux-tui.sh fetch 2>&1) || status=$?
  took=$(( $(date +%s) - started ))
}

fail() { printf '%s (exit %s, %ss), last lines:\n%s\n' "$1" "$status" "$took" "$(tail -n 12 <<<"$out")" >&2; exit 1; }

# fast <case> <runs json> <reason text>: exit 1 well before the 40 s wait ends.
fast() {
  set_runs "$2"
  fetch 40
  [[ "$status" == 1 ]] || fail "$1: fetch did not fail"
  (( took < 30 )) || fail "$1: fetch waited instead of failing fast"
  grep -qF 'no cmux-tui artifacts run will publish' <<<"$out" || fail "$1: no fail-fast summary"
  grep -qF "$3" <<<"$out" || fail "$1: reason '$3' missing"
}

fast cancelled \
  '{"total_count":1,"workflow_runs":[{"id":11,"status":"completed","conclusion":"cancelled","html_url":"https://github.com/o/r/actions/runs/11"}]}' \
  'cancelled: https://github.com/o/r/actions/runs/11'
fast superseded \
  '{"total_count":1,"workflow_runs":[{"id":12,"status":"completed","conclusion":"success","html_url":"https://github.com/o/r/actions/runs/12"}]}' \
  'superseded'
fast missing '{"total_count":0,"workflow_runs":[]}' "no cmux-tui artifacts run exists for $sha"

# An active run (one cancelled attempt plus a queued one) keeps the bounded wait.
set_runs '{"total_count":2,"workflow_runs":[{"id":13,"status":"completed","conclusion":"cancelled","html_url":"u13"},{"id":14,"status":"queued","conclusion":null,"html_url":"u14"}]}'
fetch 4
if [[ "$status" != 1 ]] || ! grep -qF 'is not published after' <<<"$out"; then fail "active run: expected the bounded wait"; fi
grep -qF 'no cmux-tui artifacts run will publish' <<<"$out" && fail "active run: failed fast"

# An unreadable API fails open: the bounded wait decides.
rm -f "$runs_dir/runs"
fetch 4
if [[ "$status" != 1 ]] || ! grep -qF 'is not published after' <<<"$out"; then fail "unreadable API: expected the bounded wait"; fi
grep -qF 'no cmux-tui artifacts run will publish' <<<"$out" && fail "unreadable API: failed fast"

printf 'pin-cmux-tui run-check tests: ok\n'
