#!/usr/bin/env bash
# Pin the gh-merge-green that every session runs to a tested origin/main commit.
#
# ~/.local/bin/gh-merge-green used to be a symlink into a live cmux working
# checkout. On 2026-10-19 an agent switched that checkout's branch and edited
# the script in place; the half-edited file broke every session's merges.
#
# This installs one origin/main commit as a read-only, locked, sparse git
# worktree under $GH_MERGE_GREEN_HOME/snapshots/<sha>, runs the gh-merge-green
# tests inside it, and only then points $GH_MERGE_GREEN_HOME/current at it.
# ~/.local/bin/gh-merge-green links to current/scripts/gh-merge-green-pinned,
# which runs that snapshot and refreshes it in the background. Edits, branch
# switches or a dirty tree in the source checkout never reach the snapshot:
# it is built from git objects, not from anyone's working tree.
#
# A Mac that runs no test suites (build role submitter-only, Leo's Macs) skips
# the local run and installs a commit only after main's "CI fast guards" check
# passed for it, read through glaeda-gh; until then it keeps the current
# install. GH_MERGE_GREEN_TESTS=local|ci overrides the choice.
#
# usage:
#   install-gh-merge-green.sh install [--repo DIR] [--ref REF] [--bin DIR] [--skip-tests] [--force]
#   install-gh-merge-green.sh update [--background] [--if-stale SECONDS]
#   install-gh-merge-green.sh repair SNAPSHOT
#   install-gh-merge-green.sh status
#
# --repo is any cmux clone whose origin is GitHub (first install only; it is
# remembered). REF must be origin/main or one of its ancestors.
set -euo pipefail

GMG_HOME="${GH_MERGE_GREEN_HOME:-$HOME/.local/share/gh-merge-green}"
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
# What the installed command runs. A new origin/main commit that leaves these
# unchanged needs no new snapshot.
PINNED_PATHS=(scripts/gh-merge-green scripts/ci scripts/gh-merge-green-pinned scripts/install-gh-merge-green.sh)
SPARSE_PATTERNS=(/scripts/ /tests/ /.github/)
DEFAULT_TESTS="tests.test_gh_merge_green tests.test_gh_merge_green_revert tests.test_base_red_excuse tests.test_merge_fast_gate tests.test_merge_check_paths tests.test_review_receipt tests.test_merge_freeze tests.test_pr_proof_section tests.test_install_gh_merge_green"
KEEP_SNAPSHOTS=3
# Leo's Macs run no test suites (their local build guards give them the
# submitter-only build role). There a main commit is installed once its main
# push passed this check, the job that runs the gh-merge-green tests in CI.
CI_TESTS_CHECK="CI fast guards / CI fast guards"

say() { printf 'install-gh-merge-green: %s\n' "$*" >&2; }
die() { say "error: $*"; exit 1; }

replace_link() { # TARGET LINK: atomically point LINK at TARGET
  local tmp="$2.tmp.$$"
  rm -f "$tmp"
  ln -s "$1" "$tmp"
  python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$tmp" "$2"
}

age_seconds() { # PATH: seconds since mtime, or a huge number when missing
  python3 -c 'import os, sys, time
try: print(int(time.time() - os.stat(sys.argv[1]).st_mtime))
except OSError: print(10**9)' "$1"
}

fingerprint() { # REPO REV: the object ids of the pinned paths at REV
  local repo="$1" rev="$2" path out=""
  for path in "${PINNED_PATHS[@]}"; do
    out+="$(git -C "$repo" rev-parse --verify --quiet "$rev:$path" || echo -) "
  done
  printf '%s\n' "$out"
}

# The lock is a directory that already holds its owner's pid when it appears:
# it is built under a private name and renamed into place, which fails while
# another lock exists. A lock whose owner has exited is renamed away (only one
# contender wins that rename) and removed. Only the owner releases its lock.
rename_dir() { python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$1" "$2" 2>/dev/null; }

acquire_lock() { # exit 0 when held, 1 when another live installer holds it
  local lock="$GMG_HOME/lock" mine="$GMG_HOME/lock.new.$$" stale="$GMG_HOME/lock.stale.$$" pid _
  mkdir -p "$GMG_HOME"
  rm -rf "$mine"
  mkdir "$mine" && echo "$$" > "$mine/pid"
  for _ in 1 2; do
    if [ ! -e "$lock" ] && rename_dir "$mine" "$lock"; then
      trap 'release_lock' EXIT
      return 0
    fi
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      break
    fi
    [ -n "$pid" ] || break  # the lock is mid-rename by another installer
    rename_dir "$lock" "$stale" && rm -rf "$stale"
  done
  rm -rf "$mine"
  return 1
}

release_lock() {
  [ "$(cat "$GMG_HOME/lock/pid" 2>/dev/null)" = "$$" ] || return 0
  rename_dir "$GMG_HOME/lock" "$GMG_HOME/lock.done.$$" && rm -rf "$GMG_HOME/lock.done.$$"
}

saved() { cat "$GMG_HOME/$1" 2>/dev/null || true; }

exclude_spotlight_marker() { # REPO: Spotlight's marker is not a change, in any worktree of REPO
  local exclude
  exclude="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "${exclude%/*}"
  grep -qxF .metadata_never_index "$exclude" 2>/dev/null && return 0
  # A last line without its newline would swallow the new pattern.
  if [ -s "$exclude" ] && [ -n "$(tail -c 1 "$exclude")" ]; then printf '\n' >> "$exclude"; fi
  printf '.metadata_never_index\n' >> "$exclude"
}

set_files_writable() { # SNAPSHOT MODE(+w|-w)
  local snap="$1" mode="$2" path
  for path in "${PINNED_PATHS[@]}"; do
    [ -e "$snap/$path" ] || continue
    if [ "$mode" = +w ]; then
      find "$snap/$path" -type f -exec chmod u+w {} + 2>/dev/null || true
    else
      find "$snap/$path" -type f -exec chmod a-w {} + 2>/dev/null || true
    fi
  done
}

remove_snapshot() { # REPO SNAPSHOT
  local repo="$1" snap="$2"
  [ -d "$snap" ] || return 0
  set_files_writable "$snap" +w
  git -C "$repo" worktree unlock "$snap" 2>/dev/null || true
  git -C "$repo" worktree remove --force "$snap" 2>/dev/null || rm -rf "$snap"
  git -C "$repo" worktree prune 2>/dev/null || true
}

run_tests() { # SNAPSHOT
  local snap="$1" modules=() module
  for module in ${GH_MERGE_GREEN_INSTALL_TESTS:-$DEFAULT_TESTS}; do
    [ -f "$snap/${module//.//}.py" ] && modules+=("$module")
  done
  [ "${#modules[@]}" -gt 0 ] || { say "no gh-merge-green tests found in $snap"; return 1; }
  say "running ${#modules[@]} test modules in $snap"
  (cd "$snap" && PYTHONPATH="$snap/tests${PYTHONPATH:+:$PYTHONPATH}" GH_MERGE_GREEN_NO_AUTO_UPDATE=1 python3 -m unittest "${modules[@]}")
}

tests_where() { # local, or ci on a Mac that runs no test suites
  case "${GH_MERGE_GREEN_TESTS:-}" in local|ci) echo "$GH_MERGE_GREEN_TESTS"; return 0 ;; esac
  local role="${CMUX_LOCAL_BUILD_GUARDS_DIR:-$HOME/.local/lib/cmux-local-build-guards}/build-role"
  if [ -f "$role" ] && [ "$(cat "$role")" = submitter-only ]; then echo ci; else echo local; fi
}

ci_tests_verdict() { # SHA: success, failure or pending, read once through glaeda-gh
  local out
  out="$("${GH_MERGE_GREEN_GLAEDA:-glaeda-gh}" checks manaflow-ai/cmux "$1" \
    --consumer gh-merge-green-install --json 2>/dev/null)" || { echo pending; return 0; }
  printf '%s' "$out" | python3 -c 'import json, sys
try:
    state = json.load(sys.stdin)["heads"][sys.argv[1]]["found"][sys.argv[2]]
except (ValueError, KeyError, TypeError):
    state = None
if state and state[0] == "completed" and state[1] == "success":
    print("success")
elif state and state[0] == "completed" and state[1] in ("failure", "timed_out"):
    print("failure")
else:
    print("pending")' "$1" "$CI_TESTS_CHECK"
}

prune_snapshots() { # REPO: keep current and the newest others, never one younger than an hour
  local repo="$1" current snap kept=0
  current="$(cd "$GMG_HOME/current" 2>/dev/null && pwd -P || true)"
  [ -d "$GMG_HOME/snapshots" ] || return 0
  # shellcheck disable=SC2045 # snapshot names are hex SHAs, newest first
  for snap in $(ls -1t "$GMG_HOME/snapshots"); do
    snap="$GMG_HOME/snapshots/$snap"
    [ "$(cd "$snap" && pwd -P)" = "$current" ] && continue
    kept=$((kept + 1))
    [ "$kept" -lt "$KEEP_SNAPSHOTS" ] && continue
    [ "$(age_seconds "$snap")" -lt 3600 ] && continue
    remove_snapshot "$repo" "$snap"
  done
}

link_bin() { # BIN_DIR
  local bin="$1" link="$1/gh-merge-green"
  mkdir -p "$bin"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    mv "$link" "$link.pre-pinned.$(date +%Y%m%d%H%M%S)"
    say "moved the existing $link aside"
  fi
  replace_link "$GMG_HOME/current/scripts/gh-merge-green-pinned" "$link"
}

cmd_install() {
  local repo="" ref="" bin="" skip_tests=0 force=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --ref) ref="$2"; shift 2 ;;
      --bin) bin="$2"; shift 2 ;;
      --skip-tests) skip_tests=1; shift ;;
      --force) force=1; shift ;;
      *) die "unknown install argument: $1" ;;
    esac
  done
  repo="${repo:-$(saved repo)}"
  bin="${bin:-$(saved bin)}"
  bin="${bin:-$HOME/.local/bin}"
  [ -n "$repo" ] || die "pass --repo DIR (a cmux clone whose origin is GitHub) on the first install"
  repo="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
    die "--repo is not a git checkout"
  # Worktrees are added from the main checkout of that repository.
  repo="$(git -C "$repo/.." rev-parse --show-toplevel 2>/dev/null || dirname "$repo")"
  # Exact URLs only: a lookalike host (evilgithub.com) must not be fetched and tested.
  case "$(git -C "$repo" remote get-url origin 2>/dev/null)" in
    https://github.com/manaflow-ai/cmux|https://github.com/manaflow-ai/cmux.git) ;;
    git@github.com:manaflow-ai/cmux|git@github.com:manaflow-ai/cmux.git) ;;
    ssh://git@github.com/manaflow-ai/cmux|ssh://git@github.com/manaflow-ai/cmux.git) ;;
    *) [ "${GH_MERGE_GREEN_INSTALL_ANY_ORIGIN:-0}" = 1 ] || die "$repo's origin is not github.com/manaflow-ai/cmux" ;;
  esac
  acquire_lock || { say "another install is running; leaving it to finish"; return 0; }
  mkdir -p "$GMG_HOME/snapshots"
  printf '%s\n' "$repo" > "$GMG_HOME/repo"
  printf '%s\n' "$bin" > "$GMG_HOME/bin"
  exclude_spotlight_marker "$repo"

  git -C "$repo" fetch --quiet origin main || die "cannot fetch origin main in $repo"
  touch "$GMG_HOME/last-check"
  local sha main snap
  sha="$(git -C "$repo" rev-parse --verify --quiet "${ref:-refs/remotes/origin/main}^{commit}")" ||
    die "unknown ref ${ref:-origin/main}"
  main="$(git -C "$repo" rev-parse refs/remotes/origin/main)"
  git -C "$repo" merge-base --is-ancestor "$sha" "$main" ||
    die "$sha is not on origin/main; only reviewed main commits are installed"
  local entry
  for entry in scripts/gh-merge-green scripts/gh-merge-green-pinned scripts/install-gh-merge-green.sh; do
    git -C "$repo" cat-file -e "$sha:$entry" 2>/dev/null ||
      die "${sha:0:10} has no $entry, so it cannot be installed this way"
  done

  if [ "$force" = 0 ] && [ -d "$GMG_HOME/current" ] &&
     [ "$(fingerprint "$repo" "$sha")" = "$(fingerprint "$GMG_HOME/current" HEAD)" ]; then
    printf '%s\n' "$sha" > "$GMG_HOME/checked"
    rm -f "$GMG_HOME/failed"
    link_bin "$bin"
    say "already current: $(git -C "$GMG_HOME/current" rev-parse --short HEAD) runs the same gh-merge-green as ${sha:0:10}"
    return 0
  fi

  local where=skip
  [ "$skip_tests" = 1 ] || where="$(tests_where)"
  if [ "$where" = ci ]; then
    case "$(ci_tests_verdict "$sha")" in
      success) say "${sha:0:10} passed \"$CI_TESTS_CHECK\" on main, which runs the gh-merge-green tests; this Mac runs no test suites" ;;
      failure)
        printf '%s\n' "$sha" > "$GMG_HOME/failed"
        die "\"$CI_TESTS_CHECK\" failed at ${sha:0:10}; kept the current install" ;;
      *)
        say "\"$CI_TESTS_CHECK\" has not passed at ${sha:0:10} yet; kept the current install, the next update checks again"
        return 0 ;;
    esac
  fi

  # A fresh directory every time: the live snapshot is never removed or rebuilt
  # in place, so a failed or forced install leaves the working command alone.
  snap="$GMG_HOME/snapshots/$sha-$(date +%Y%m%d%H%M%S)-$$"
  git -C "$repo" worktree add --quiet --detach --no-checkout "$snap" "$sha"
  git -C "$snap" sparse-checkout set --no-cone "${SPARSE_PATTERNS[@]}"
  git -C "$snap" checkout --quiet --detach "$sha"
  if [ "$where" = local ] && ! run_tests "$snap"; then
    remove_snapshot "$repo" "$snap"
    printf '%s\n' "$sha" > "$GMG_HOME/failed"
    die "gh-merge-green tests failed at ${sha:0:10}; kept the current install"
  fi
  # Tests may leave caches behind; the snapshot must match its commit exactly.
  git -C "$snap" clean -fdxq
  if ! git -C "$snap" diff --quiet HEAD; then
    remove_snapshot "$repo" "$snap"
    die "snapshot for ${sha:0:10} differs from its commit after its tests; kept the current install"
  fi
  set_files_writable "$snap" -w
  git -C "$repo" worktree lock --reason "gh-merge-green pinned install (scripts/install-gh-merge-green.sh)" "$snap"
  replace_link "snapshots/${snap##*/}" "$GMG_HOME/current"
  printf '%s\n' "$sha" > "$GMG_HOME/checked"
  rm -f "$GMG_HOME/failed"
  link_bin "$bin"
  prune_snapshots "$repo"
  say "installed gh-merge-green from origin/main ${sha:0:10} ($bin/gh-merge-green)"
}

cmd_update() {
  local background=0 if_stale=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --background) background=1; shift ;;
      --if-stale) if_stale="$2"; shift 2 ;;
      *) die "unknown update argument: $1" ;;
    esac
  done
  local repo
  repo="$(saved repo)"
  [ -n "$repo" ] || die "not installed; run: $SELF install --repo DIR"
  if [ -n "$if_stale" ] && [ "$(age_seconds "$GMG_HOME/last-check")" -lt "$if_stale" ]; then
    return 0
  fi
  touch "$GMG_HOME/last-check"
  if [ "$background" = 1 ]; then
    nohup "$SELF" update >>"$GMG_HOME/update.log" 2>&1 </dev/null &
    return 0
  fi
  git -C "$repo" fetch --quiet origin main || die "cannot fetch origin main in $repo"
  local main
  main="$(git -C "$repo" rev-parse refs/remotes/origin/main)"
  [ "$main" = "$(saved checked)" ] && return 0
  if [ "$main" = "$(saved failed)" ]; then
    say "origin/main ${main:0:10} already failed the gh-merge-green tests; waiting for a newer commit"
    return 1
  fi
  cmd_install --ref "$main"
}

cmd_repair() { # SNAPSHOT: restore an in-place edit from the snapshot's own commit
  local snap="$1"
  [ -d "$snap" ] || die "no snapshot at $snap"
  set_files_writable "$snap" +w
  git -C "$snap" checkout --quiet HEAD -- "${PINNED_PATHS[@]}" 2>/dev/null ||
    git -C "$snap" checkout --quiet HEAD -- scripts/gh-merge-green scripts/ci
  set_files_writable "$snap" -w
  git -C "$snap" diff --quiet HEAD -- "${PINNED_PATHS[@]}"
}

cmd_status() {
  local current
  printf 'home     %s\n' "$GMG_HOME"
  printf 'repo     %s\n' "$(saved repo)"
  if current="$(git -C "$GMG_HOME/current" rev-parse HEAD 2>/dev/null)"; then
    printf 'current  %s\n' "$current"
  else
    printf 'current  (none)\n'
  fi
  printf 'checked  %s\n' "$(saved checked)"
  [ -f "$GMG_HOME/failed" ] && printf 'failed   %s (origin/main commit whose tests failed)\n' "$(saved failed)"
  printf 'command  %s -> %s\n' "$(saved bin)/gh-merge-green" "$(readlink "$(saved bin)/gh-merge-green" 2>/dev/null || echo '(missing)')"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  update) shift; cmd_update "$@" ;;
  repair) shift; cmd_repair "$@" ;;
  status) shift; cmd_status ;;
  *) sed -n '2,24p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
