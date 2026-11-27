#!/usr/bin/env bash
# Check out the submodules a media tour's base or before app builds from
# (.github/workflows/cmux-next-media.yml):
#
#   media_tree_submodules.sh TREE [HEAD_CHECKOUT]
#
# TREE is a worktree of HEAD_CHECKOUT (default GITHUB_WORKSPACE). Only ghostty
# and ghostty-next: no app build reads homebrew-cmux. A pin the head checkout
# already holds comes from its own .git/modules clone with no network; any
# other fetches one commit (--depth 1), not the whole history. A failed update
# tries again twice, 30 s apart.
#
# Run 45837430593 lost every before at 8f9660c2 this way: a full ghostty-next
# clone ran 3 min, ended in curl 18, and the git shim's github.com fallback met
# a refused proxy (127.0.0.1:18434) in the same second, with no second try.
set -euo pipefail
tree="$1"
head="${2:-${GITHUB_WORKSPACE:-$PWD}}"
retry_seconds="${MEDIA_SUBMODULE_RETRY_SECONDS:-30}"
modules="$(git -C "$head" rev-parse --path-format=absolute --git-common-dir)/modules"

names=()
for name in ghostty ghostty-next; do
  git -C "$tree" rev-parse --verify -q "HEAD:$name" >/dev/null && names+=("$name")
done
[ "${#names[@]}" -gt 0 ] || exit 0

# -c only: the worktree shares the head checkout's .git/config, and a url
# written there would point the head's own submodules at themselves.
local_urls=()
for name in "${names[@]}"; do
  pin="$(git -C "$tree" rev-parse "HEAD:$name")"
  if git -C "$modules/$name" cat-file -e "$pin^{commit}" 2>/dev/null; then
    echo "media submodules: $name $pin from the head checkout's clone"
    local_urls+=(-c "submodule.$name.url=$modules/$name")
  fi
done

for try in 1 2 3; do
  if git -C "$tree" -c protocol.file.allow=always ${local_urls[@]+"${local_urls[@]}"} \
      submodule update --init --recursive --depth 1 -- "${names[@]}"; then
    exit 0
  fi
  [ "$try" -lt 3 ] || break
  echo "media submodules: update failed (try $try of 3); again in ${retry_seconds} s"
  sleep "$retry_seconds"
done
echo "media submodules: update failed 3 times" >&2
exit 1
