#!/usr/bin/env bash
# media_tree_submodules.sh gives a tour's base or before worktree ghostty and
# ghostty-next from the head checkout's clones when the pin matches (no
# network), never homebrew-cmux, writes no url into the shared .git/config, and
# tries a failed update three times. Run 45837430593 lost every before at
# 8f9660c2 to one dropped ghostty-next clone.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../media_tree_submodules.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 MEDIA_SUBMODULE_RETRY_SECONDS=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

for n in ghostty ghostty-next homebrew-cmux; do
  git init -q -b main "$tmp/src-$n"
  git -C "$tmp/src-$n" commit -q --allow-empty -m one
done
sup="$tmp/sup"
git init -q -b main "$sup"
for n in ghostty ghostty-next homebrew-cmux; do
  git -C "$sup" -c protocol.file.allow=always submodule add -q "$tmp/src-$n" "$n"
done
git -C "$sup" commit -q -m base
base="$(git -C "$sup" rev-parse HEAD)"
git -C "$sup/ghostty-next" commit -q --allow-empty -m two
git -C "$sup" add ghostty-next
git -C "$sup" commit -q -m head
urls_before="$(git -C "$sup" config --get-regexp 'submodule\..*\.url')"

# ghostty's origin is gone: the base's pins must come from the head's clones.
mv "$tmp/src-ghostty" "$tmp/src-ghostty.gone"
git -C "$sup" worktree add -q --detach "$tmp/before" "$base"
bash "$script" "$tmp/before" "$sup" >"$tmp/out" 2>&1 || { cat "$tmp/out"; fail "update from the head's clones failed"; }
for n in ghostty ghostty-next; do
  [ "$(git -C "$tmp/before/$n" rev-parse HEAD)" = "$(git -C "$tmp/before" rev-parse "HEAD:$n")" ] || fail "$n not at its pin"
done
[ -z "$(ls -A "$tmp/before/homebrew-cmux")" ] || fail "homebrew-cmux was checked out"
[ "$(git -C "$sup" config --get-regexp 'submodule\..*\.url')" = "$urls_before" ] || fail "the head's submodule urls changed"

# A pin nowhere reachable fails after three tries.
mv "$sup/.git/modules/ghostty" "$tmp/ghostty-module.gone"
git -C "$sup" worktree add -q --detach "$tmp/before2" "$base"
if bash "$script" "$tmp/before2" "$sup" >"$tmp/out2" 2>&1; then fail "an unreachable pin passed"; fi
grep -q 'try 2 of 3' "$tmp/out2" || { cat "$tmp/out2"; fail "no third try"; }
grep -q 'update failed 3 times' "$tmp/out2" || fail "no final failure line"
echo "media-tree-submodules: ok"
