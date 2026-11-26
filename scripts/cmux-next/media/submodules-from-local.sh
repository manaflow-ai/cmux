#!/usr/bin/env bash
# Check out TREE's submodules (nested too), reading each one from a local git directory that already holds
# its pinned commit, over file://, so no network and no proxy is in the way. Submodules with no local copy
# go to their URL as before.
#
# usage: submodules-from-local.sh TREE [DONOR_DIR...]
#
# Where a copy is looked for, in order:
#   - the fleet's submodule mirrors, $GLAEDA_GIT_MIRROR_DIR/submodules/*.git (glaeda-git-mirror keeps one bare
#     mirror per cmux submodule, each pin as refs/pins/<sha>, glaeda.url naming its GitHub URL; the same
#     mirrors nightly.yml's warm checkout reads);
#   - every git directory under each DONOR_DIR (a superproject's .git, whose modules/ holds its submodules'
#     git directories), matched on remote.origin.url. The media tour passes the head checkout's .git: the
#     ghostty-next pin rarely moves, so the head checkout usually holds a before tree's pin already.
# A copy is used only when it holds the gitlink commit, so a stale copy falls through to the URL.
#
# Why: run 45837430593 (job 139976029698) cloned ghostty-next for before tree 8f9660c2 from github.com. The
# transfer died ("curl 18", "early EOF"), and every retry, the runner's git shim fallback included, then failed
# in 0 ms on a dead local proxy (127.0.0.1:18434). 3 What's New befores had no app. Retrying the same route
# cannot fix that; not using the network can.
set -uo pipefail

tree=${1:?usage: submodules-from-local.sh TREE [DONOR_DIR...]}
shift
donors=("$@")
mirror_root="${GLAEDA_GIT_MIRROR_DIR:-/Users/Shared/cmux-build-fleet/git}/submodules"

normurl() { printf '%s' "$1" | sed -E 's#/+$##; s#\.git$##' | tr '[:upper:]' '[:lower:]'; }

# Candidate git directories as "DIR<TAB>normalized URL", read once.
candidates=$(
  for d in "$mirror_root"/*.git; do
    [ -d "$d/objects" ] && [ ! -L "$d/objects" ] && [ ! -L "$d" ] && [ -f "$d/HEAD" ] || continue
    u=$(git --git-dir="$d" config --get glaeda.url 2>/dev/null) || continue
    printf '%s\t%s\n' "$d" "$(normurl "$u")"
  done
  for donor in ${donors[@]+"${donors[@]}"}; do
    [ -d "$donor/modules" ] || continue
    find "$donor/modules" -maxdepth 8 -name HEAD -type f 2>/dev/null | while read -r head; do
      d=${head%/HEAD}
      [ -d "$d/objects" ] || continue
      u=$(git --git-dir="$d" config --get remote.origin.url 2>/dev/null) || continue
      printf '%s\t%s\n' "$d" "$(normurl "$u")"
    done
  done
)

copy_for() {  # URL COMMIT: a local git directory for URL that holds COMMIT
  local want d u
  want=$(normurl "$1")
  while IFS=$'\t' read -r d u; do
    [ -n "$d" ] && [ "$u" = "$want" ] || continue
    git --git-dir="$d" cat-file -e "$2^{commit}" 2>/dev/null && { printf '%s' "$d"; return 0; }
  done <<<"$candidates"
  return 1
}

map_submodules() {  # GIT_DIR COMMIT: "COPY<TAB>URL" for each submodule (nested too) with a local copy
  local key sub url gitlink m
  { git --git-dir="$1" config --blob "$2:.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null || true; } \
    | while read -r key sub; do
      url=$(git --git-dir="$1" config --blob "$2:.gitmodules" --get "${key%.path}.url" 2>/dev/null) || continue
      gitlink=$(git --git-dir="$1" rev-parse -q --verify "$2:$sub" 2>/dev/null) || continue
      m=$(copy_for "$url" "$gitlink") || continue
      printf '%s\t%s\n' "$m" "$url"
      map_submodules "$m" "$gitlink" || true
    done
}

tree_git=$(git -C "$tree" rev-parse --absolute-git-dir) || exit 1
head=$(git -C "$tree" rev-parse HEAD) || exit 1
n=${GIT_CONFIG_COUNT:-0}
while IFS=$'\t' read -r m url; do
  [ -n "$m" ] || continue
  echo "submodule $url: from the local copy $m"
  export "GIT_CONFIG_KEY_$n=url.file://$m.insteadOf" "GIT_CONFIG_VALUE_$n=$url"
  n=$((n + 1))
done < <(map_submodules "$tree_git" "$head" | sort -u -t $'\t' -k2,2)
if [ "$n" -gt "${GIT_CONFIG_COUNT:-0}" ]; then
  export "GIT_CONFIG_KEY_$n=protocol.file.allow" "GIT_CONFIG_VALUE_$n=always"
  export GIT_CONFIG_COUNT=$((n + 1))
fi
exec git -C "$tree" -c protocol.version=2 submodule update --init --recursive
