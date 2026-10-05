#!/usr/bin/env bash
# A reused self-hosted runner workspace (a glaeda mini) keeps the previous
# job's submodule checkouts: actions/checkout with `submodules: false` moves
# the superproject to this commit but leaves a submodule at the last branch's
# commit, so `git status` reports ` M ghostty-next` and pin-cmux-tui.sh fetch
# refuses the checkout as dirty (run 37198483749, job 111425574861). A fresh
# Blacksmith checkout has no submodule checkouts and passes.
# scripts/ci/reset-stale-submodules.sh must make the reused workspace match a
# fresh checkout, while a real cmux-tui edit is still refused.
# No network: the CDN base is unreachable, so a fetch that gets past the dirty
# check stops at "is not published".
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
RESET="$ROOT/scripts/ci/reset-stale-submodules.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main -c protocol.file.allow=always "$@" >/dev/null 2>&1; }
fail() { printf '%s\n' "$@" >&2; exit 1; }

# ghostty-next (the submodule cmux-tui builds from, CMUX-TUI-TREE-KEY-V2):
# two commits; the superproject pins the second (B).
git_q init "$TMP/ghostty-src"
echo a > "$TMP/ghostty-src/f"; git_q -C "$TMP/ghostty-src" add f; git_q -C "$TMP/ghostty-src" commit -m A
commit_a=$(git -C "$TMP/ghostty-src" rev-parse HEAD)
echo b > "$TMP/ghostty-src/f"; git_q -C "$TMP/ghostty-src" commit -am B
commit_b=$(git -C "$TMP/ghostty-src" rev-parse HEAD)

ws="$TMP/ws"
git_q init "$ws"
mkdir -p "$ws/cmux-tui" "$ws/scripts/cmux-next"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$ws/scripts/cmux-next/"
mkdir -p "$ws/scripts/ci"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$ws/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$ws/scripts/cmux-next/"
echo reducer > "$ws/scripts/cmux-next/build-layout-reducer-ffi.sh"
echo one > "$ws/cmux-tui/a"
git_q -C "$ws" submodule add "$TMP/ghostty-src" ghostty-next
git_q -C "$ws" add -A
git_q -C "$ws" commit -m superproject
[[ "$(git -C "$ws" rev-parse HEAD:ghostty-next)" == "$commit_b" ]] || fail "setup: gitlink is not B"

# What the previous job on the runner left: ghostty-next checked out at another commit.
git_q -C "$ws/ghostty-next" checkout --detach "$commit_a"

dirty() { git -C "$ws" status --porcelain --ignore-submodules=dirty -- cmux-tui ghostty-next; }
fetch() { # -> "<status> <output>"
  local status=0 out
  out=$(cd "$ws" && env -u CI_JOB_DIR -u CMUX_NEXT_TUI_ALLOW_DIRTY GITHUB_ACTIONS=true \
    CMUX_TUI_PIN_BASE=https://127.0.0.1:9/cmux-tui CMUX_TUI_TREE_WAIT_SECONDS=0 \
    bash scripts/cmux-next/pin-cmux-tui.sh fetch 2>&1) || status=$?
  printf '%s %s' "$status" "$out"
}

[[ "$(dirty)" == " M ghostty-next" ]] || fail "setup: stale ghostty-next is not reported as ' M ghostty-next':" "$(dirty)"
out=$(fetch)
grep -q 'uncommitted cmux-tui source changes' <<<"$out" || fail "setup: the stale workspace was not refused:" "$out"

# The reset drops the stale submodule checkout, as on a fresh checkout.
[[ -x "$RESET" ]] || fail "missing $RESET"
"$RESET" "$ws" || fail "reset-stale-submodules.sh failed on a stale workspace"
[[ -z "$(dirty)" ]] || fail "the reset left the workspace dirty:" "$(dirty)"
out=$(fetch)
if grep -q 'uncommitted cmux-tui source changes' <<<"$out"; then fail "pin-cmux-tui still refused the reset workspace:" "$out"; fi
grep -q 'is not published' <<<"$out" || fail "fetch did not reach the published-tree check:" "$out"

# Idempotent on a workspace with no initialized submodule (a fresh checkout).
"$RESET" "$ws" || fail "a second reset failed"
git_q init "$TMP/plain"; git_q -C "$TMP/plain" commit --allow-empty -m empty
"$RESET" "$TMP/plain" || fail "reset failed on a repository without submodules"

# A later checkout that wants ghostty-next re-inits it at the gitlink from the kept objects.
git_q -C "$ws" submodule update --init ghostty-next || fail "re-init after the reset failed"
[[ "$(git -C "$ws/ghostty-next" rev-parse HEAD)" == "$commit_b" ]] || fail "re-init did not check out the gitlink"

# A real cmux-tui edit is still refused after the reset.
"$RESET" "$ws"
echo dirty > "$ws/cmux-tui/a"
out=$(fetch)
[[ "$out" == "1 "* ]] && grep -q 'uncommitted cmux-tui source changes' <<<"$out" \
  || fail "a real cmux-tui edit was not refused after the reset:" "$out"
printf 'reset-stale-submodules tests: ok\n'
