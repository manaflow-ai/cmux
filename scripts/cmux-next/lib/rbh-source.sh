# shellcheck shell=bash
# Sourced after origin-net.sh (net_retry). generate-third-party-notices.sh reads the remote browser
# host crate at its pin's source_commit from this fetch.
#
# rbh_fetch_source ROOT GIT_DIR REV REMOTE: makes GIT_DIR a fresh repository whose FETCH_HEAD is REV.
#
# A full checkout at ROOT lends its objects (and, on a warm nightly builder, the fleet mirror's that
# it borrows), so the remote sends only what REV adds. A lone `--depth 1` fetch asks GitHub to pack
# the whole tree: nightly run 45796327994 (2026-11-26) lost 48 min to it, every attempt ending
# `curl 56` / `bad pack header` (reproduced off the fleet too), while the same fetch with the mirror
# lent took 33 s and 244 KB. A shallow ROOT cannot lend its history (the remote would leave out
# objects only its missing ancestors hold), so it, and a failed lent fetch, take the lone fetch.
rbh_fetch_source() {
  local root="$1" dir="$2" rev="$3" remote="$4"
  rm -rf "$dir" && git init --quiet "$dir"
  if [[ "$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null)" == false ]]; then
    local lent
    lent="$(git -C "$dir" rev-parse --path-format=absolute --git-path objects/info/alternates)"
    mkdir -p "$(dirname "$lent")"
    git -C "$root" rev-parse --path-format=absolute --git-path objects >"$lent"
    if git -C "$dir" cat-file -e "$rev^{commit}" 2>/dev/null; then
      printf '%s\n' "$rev" >"$(git -C "$dir" rev-parse --path-format=absolute --git-path FETCH_HEAD)"
      echo "remote browser host source $rev: already in this checkout's objects"
      return 0
    fi
    if net_retry "fetch the remote browser host source $rev beside this checkout's objects" \
      git -C "$dir" fetch --no-recurse-submodules --quiet --no-tags "$remote" "$rev"; then
      echo "remote browser host source $rev: fetched beside this checkout's objects"
      return 0
    fi
    echo "warn: fetching $rev beside this checkout's objects failed; fetching it alone" >&2
    rm -rf "$dir" && git init --quiet "$dir"
  fi
  net_retry "fetch the remote browser host source $rev" git -C "$dir" fetch --no-recurse-submodules --quiet --depth 1 "$remote" "$rev"
}
