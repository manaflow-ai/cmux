#!/usr/bin/env bash
# git-seed.sh save WORKSPACE
# git-seed.sh restore WORKSPACE
#
# Start a macOS checkout from main's git objects instead of an empty directory.
#
# actions/checkout fetches the tested commit with --depth=1 into an empty
# repository, so every macOS job downloads the whole tree: 129 MB in 29 s for
# the main repository, then 17 s for its submodules, most of it ghostty, whose
# depth-1 clone fetches its default branch before the pinned commit (job
# 107695138963). A fetch into a repository that already holds a recent main
# sends only what changed since: 92 KB to 1.2 MB in under a second for pull
# request merge commits measured on 2026-09-24, and a submodule whose pinned
# commit is already present is not fetched at all.
#
# `save` runs in a main-branch job after its checkout and publishes the
# repository's objects to R2 under git-seed-v1-<commit>. Only objects, the
# shallow list and commit ids travel: no config, hooks, index or credentials.
#
# `restore` runs before actions/checkout on a runner with no repository yet.
# It builds a repository whose HEAD is the seed commit and whose origin is the
# URL actions/checkout expects, so checkout keeps it: it resets to HEAD, then
# fetches the tested commit against those objects. Submodule git directories
# go where `git submodule update` looks for them, and it reuses them. The
# repository is assembled aside and renamed into place last, so any failure
# leaves the workspace empty and checkout clones from scratch, as it always
# has. Correctness never depends on the seed: checkout fetches and
# checks out the exact commit it was asked for.
#
# Seeds are written only by main-branch jobs holding the R2 credentials, the
# same trust as the Swift package and DerivedData seeds these jobs restore.
set -euo pipefail

mode="${1:-}"
workspace="${2:-${GITHUB_WORKSPACE:-$PWD}}"
PREFIX="git-seed-v1-"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: git-seed.sh save|restore WORKSPACE" >&2
  exit 2
}

is_commit_id() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

# Submodule names and paths from a .gitmodules file on stdin, as "name<TAB>path".
submodules() {
  git config --file - --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | sed -E 's/^submodule\.(.*)\.path (.*)$/\1\t\2/' || true
}

stage_seed() { # <stage>; copies the seed out of WORKSPACE's repository
  local stage="$1" head
  cd "$workspace"
  head="$(git rev-parse HEAD)"
  is_commit_id "$head" || { echo "git-seed: HEAD is not a commit" >&2; exit 1; }
  mkdir -p "$stage"
  cp -cR .git/objects "$stage/objects" 2>/dev/null || cp -R .git/objects "$stage/objects"
  [ ! -f .git/shallow ] || cp .git/shallow "$stage/shallow"
  echo "$head" > "$stage/HEAD"
  local name path gitdir commit
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] || continue
    gitdir=".git/modules/$name"
    [ -d "$gitdir/objects" ] || continue
    commit="$(git -C "$path" rev-parse HEAD 2>/dev/null)" || continue
    is_commit_id "$commit" || continue
    mkdir -p "$stage/modules/$name"
    cp -cR "$gitdir/objects" "$stage/modules/$name/objects" 2>/dev/null \
      || cp -R "$gitdir/objects" "$stage/modules/$name/objects"
    [ ! -f "$gitdir/shallow" ] || cp "$gitdir/shallow" "$stage/modules/$name/shallow"
    echo "$commit" > "$stage/modules/$name/HEAD"
  done < <(submodules < .gitmodules)
}

save() {
  local scratch head
  head="$(git -C "$workspace" rev-parse HEAD)"
  scratch="$(mktemp -d)"
  bash "${BASH_SOURCE[0]}" stage "$workspace" "$scratch/seed"
  "$HERE/r2-cache.sh" save "$scratch/seed" "$PREFIX$head"
  rm -rf "$scratch"
}

fetch_seed() { # <stage>; downloads and unpacks the newest seed
  local stage="$1" base key
  base="${CI_CACHE_R2_PUBLIC_URL:?CI_CACHE_R2_PUBLIC_URL is not set}"
  base="${base%/}/v1/${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}"
  key="$(curl --fail --silent --show-error --location --connect-timeout 10 --max-time 20 \
    "$base/latest/$PREFIX" | head -c 512 | tr -d '[:space:]')"
  [[ "$key" =~ ^${PREFIX}[0-9a-f]{40}$ ]] || { echo "git-seed: no seed pointer"; return 1; }
  mkdir -p "$stage"
  curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 \
    "$base/objects/$key.tar.zst" | zstd -dc | tar -xf - -C "$stage"
  echo "git-seed: unpacked $key"
}

install_seed() { # <stage>
  local stage="$1" head url repo
  head="$(cat "$stage/HEAD")"
  is_commit_id "$head" || { echo "git-seed: seed HEAD is not a commit id" >&2; return 1; }
  [ -d "$stage/objects/pack" ] || { echo "git-seed: seed has no packs" >&2; return 1; }

  # Built beside the stage and renamed into the workspace last, so a step
  # killed partway leaves either no repository or a complete one.
  repo="$(dirname "$stage")/repo"
  git init -q "$repo"
  cd "$repo"
  rm -rf .git/objects
  mv "$stage/objects" .git/objects
  [ ! -f "$stage/shallow" ] || cp "$stage/shallow" .git/shallow
  # The exact URL actions/checkout compares before it keeps a repository.
  url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
  git remote add origin "$url"
  git cat-file -e "$head^{tree}"
  git update-ref refs/remotes/origin/main "$head"
  git update-ref --no-deref HEAD "$head"

  # Module URLs come from the seed commit's own .gitmodules, never the archive.
  local name path commit gitdir module_url
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] || continue
    [ -f "$stage/modules/$name/HEAD" ] && [ -d "$stage/modules/$name/objects/pack" ] || continue
    commit="$(cat "$stage/modules/$name/HEAD")"
    is_commit_id "$commit" || continue
    # Only a module at the commit main pins is worth keeping.
    [ "$(git rev-parse -q --verify "$head:$path" 2>/dev/null)" = "$commit" ] || continue
    module_url="$(git config --blob "$head:.gitmodules" "submodule.$name.url")" || continue
    gitdir=".git/modules/$name"
    mkdir -p "$gitdir/refs/heads" "$gitdir/refs/tags"
    mv "$stage/modules/$name/objects" "$gitdir/objects"
    [ ! -f "$stage/modules/$name/shallow" ] || cp "$stage/modules/$name/shallow" "$gitdir/shallow"
    echo "$commit" > "$gitdir/HEAD"
    git config --file "$gitdir/config" core.repositoryformatversion 0
    git config --file "$gitdir/config" core.bare false
    git config --file "$gitdir/config" remote.origin.url "$module_url"
    git config --file "$gitdir/config" remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git --git-dir="$gitdir" cat-file -e "$commit^{tree}" || { rm -rf "$gitdir"; continue; }
    echo "git-seed: module $name at $commit"
  done < <(git show "$head:.gitmodules" 2>/dev/null | submodules)
  mkdir -p "$workspace"
  [ ! -e "$workspace/.git" ] || { echo "git-seed: $workspace/.git appeared meanwhile" >&2; return 1; }
  mv "$repo/.git" "$workspace/.git"
  echo "git-seed: repository at $head"
}

restore() {
  if [ -e "$workspace/.git" ]; then
    echo "git-seed: $workspace already has a repository; leaving it to actions/checkout"
    return 0
  fi
  local scratch
  scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/git-seed.XXXXXX")"
  # Separate processes: errexit does not apply inside a function whose status
  # is tested, so a failed step would otherwise be installed as if it passed.
  if ! bash "${BASH_SOURCE[0]}" fetch "$workspace" "$scratch/seed" \
    || ! bash "${BASH_SOURCE[0]}" install "$workspace" "$scratch/seed"; then
    echo "git-seed: no seed installed; actions/checkout clones from scratch"
  fi
  rm -rf "$scratch"
}

case "$mode" in
  save) save ;;
  restore) restore ;;
  # Internal steps of `save` and `restore`.
  stage) stage_seed "${3:?}" ;;
  fetch) fetch_seed "${3:?}" ;;
  install) install_seed "${3:?}" ;;
  *) usage ;;
esac
