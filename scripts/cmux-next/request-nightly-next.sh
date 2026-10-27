#!/usr/bin/env bash
# Ask main's nightly.yml (job promote-nightly-next) to move nightly-next to a
# feat-cmux-next commit, but only once that commit is buildable as a nightly:
#   1. its cmux-tui tree is published (verified the way the nightly resolves
#      it: pin-cmux-tui.sh resolve-newest-published, limited to one commit), and
#   2. it is a feat-cmux-next push (a cmux-next.yml push run exists for it).
#      Since 2026-10-26 its Release compile is not awaited: the nightly build
#      compiles the app itself and publishes nothing when that fails, so the
#      feed keeps its last good build (Leo: "SKIP THE OLD FUCKING NIGHTLY
#      BUILDS THEN WE'RE JSUT BUILDING FROM THE TIP OR FUKCING / JUST FUCKING
#      USE MORE LINUX FIX THE FUCKING BUILDS"). A tip that does not compile is
#      promoted and fails in its nightly instead of being refused here, and
##   3. its generated page strings are fresh (gen-strings --check, on the commit
#      requested; a stale one is passed over for an older green one). Since
#      #21946 the tables are build output: a commit that no longer tracks them
#      passes when they generate (no translation missing).
# Both finish asynchronously, so each side asks when its half completes:
#
#   --sha <sha> --release-compile-green
#       cmux-next.yml, after the Release compile of <sha> passed. Requests <sha>
#       if its tree is published; otherwise the artifacts side asks later.
#   --tree-ready <sha>
#       cmux-tui-artifacts.yml and nightly-next-tick, once the tree of <sha> is
#       published. Requests the newest feat-cmux-next push whose tree key is the
#       same (a later app-only commit shares it), so a commit whose own
#       artifacts run was replaced by a newer push is not lost.
#
# Why: the nightly runs the TIP's nightly.yml. A tip whose tree is unpublished
# made it fall back to an older published commit, which the tip's workflow
# may not be able to build (it skips commits whose nightly.yml differs), so
# nightly-next runs 37767816879 and 37769010617 failed. A promoted commit with
# a published tree is built at the tip, by its own workflow, with its own
# daemon. Main's promote job ignores a request that does not move forward.
#
# Usage: request-nightly-next.sh --repo <owner/repo> (--sha <sha> --release-compile-green | --tree-ready <sha>)
# Run from a checkout whose HEAD is <sha>. Needs GH_TOKEN with actions: write.
# Exit 0 when a commit was requested or
# none is ready yet, 2 on bad usage, 1 on an API failure.
# Env: CMUX_NIGHTLY_NEXT_RUN_WINDOW (default 99) recent first-parent commits searched;
# CMUX_NIGHTLY_NEXT_MAX_REFUSED (default 5) unpromotable candidates passed over.
set -euo pipefail

sha="" repo="" mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) sha="${2:-}"; shift 2 ;;
    --tree-ready) sha="${2:-}"; mode=tree-ready; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --release-compile-green) mode=release-compile-green; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$mode" ]] || { echo "error: pass --sha <sha> --release-compile-green or --tree-ready <sha>" >&2; exit 2; }
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: the commit must be 40 lowercase hex characters" >&2; exit 2; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "error: --repo must be owner/repo" >&2; exit 2; }
window="${CMUX_NIGHTLY_NEXT_RUN_WINDOW:-99}"
[[ "$window" =~ ^[1-9][0-9]?$ ]] || { echo "error: CMUX_NIGHTLY_NEXT_RUN_WINDOW must be 1 to 99" >&2; exit 2; }
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
head="$(git rev-parse HEAD)"
[[ "$head" == "$sha" ]] || { echo "error: the checkout is at $head, not $sha" >&2; exit 2; }

# A commit whose nightly.yml lacks the NIGHTLY_NEXT_NOTARY_PAUSED gate would
# notarize even while the pause is on (cx-f58x), so it is never promoted.
has_notary_gate() { # <sha>
  # Read the whole file first: `git show | grep -q` fails under pipefail when
  # grep stops at an early match and git show gets SIGPIPE.
  local workflow
  workflow="$(git show "$1:.github/workflows/nightly.yml" 2>/dev/null)" || return 1
  [[ "$workflow" == *NIGHTLY_NEXT_NOTARY_PAUSED* ]]
}

# A commit whose generated page strings are stale fails the nightly's web
# bundle step about 30 minutes in (nightly-next run 38348747848: a GitHub PR
# merge brought back settings strings another commit had retired). Every
# candidate is checked before it is requested (node, about 0.2 s): the checkout
# in place, any other commit in a detached worktree of that commit (cx-5hvb5:
# in --tree-ready mode a newer commit than the checkout used to be requested
# unchecked). A stale candidate is passed over for the next older one.
strings_tmp=""
cleanup_strings() {
  if [[ -n "$strings_tmp" ]]; then
    git worktree remove --force "$strings_tmp/wt" >/dev/null 2>&1 || rm -rf "$strings_tmp/wt"
    rm -rf "$strings_tmp"
    git worktree prune >/dev/null 2>&1 || true
    strings_tmp=""
  fi
}
trap cleanup_strings EXIT
strings_fresh() { # <sha>
  local root="$repo_root" rc=0
  if [[ "$1" != "$head" ]]; then
    cleanup_strings
    strings_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nightly-next-strings.XXXXXX")"
    if ! git worktree add -q --detach "$strings_tmp/wt" "$1" >/dev/null 2>&1; then
      echo "warning: could not check out ${1:0:12} to check its page strings; treating them as stale" >&2
      cleanup_strings
      return 1
    fi
    root="$strings_tmp/wt"
  fi
  if [[ ! -f "$root/webviews/scripts/pages/gen-strings.mjs" ]]; then
    [[ "$1" == "$head" ]] || cleanup_strings
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "warning: no node on this runner; the page strings of ${1:0:12} are not checked" >&2
    [[ "$1" == "$head" ]] || cleanup_strings
    return 0
  fi
  if git -C "$root" ls-files --error-unmatch webviews/src/pages/settings/generated/strings.json >/dev/null 2>&1; then
    (cd "$root/webviews" && node scripts/pages/gen-strings.mjs --check) || rc=$?
  else
    (cd "$root/webviews" && node scripts/pages/gen-strings.mjs) || rc=$?
  fi
  [[ "$1" == "$head" ]] || cleanup_strings
  return "$rc"
}

# The commit nightly-next points at now, when it is in this checkout's history
# (empty otherwise). It bounds the --tree-ready search from below, and a commit
# it already contains is never requested again: main's promote job keeps one
# waiting request, so a stale request would evict a newer one.
promoted=""
if line="$(git ls-remote origin refs/heads/nightly-next 2>/dev/null)" \
   && [[ "${line%%[[:space:]]*}" =~ ^[0-9a-f]{40}$ ]]; then
  promoted="${line%%[[:space:]]*}"
fi
already_promoted() { # <sha>
  # Equality needs no history: cmux-next.yml checks out one commit.
  [[ -n "$promoted" ]] || return 1
  [[ "$1" != "$promoted" ]] || return 0
  git cat-file -e "$promoted^{commit}" 2>/dev/null && git merge-base --is-ancestor "$1" "$promoted" 2>/dev/null
}

# request <sha>: 0 = requested or already on nightly-next, 1 = not promotable
# (no gate, stale strings), 2 = the dispatch itself failed (an API error: the
# caller exits 1).
request() { # <sha>
  if already_promoted "$1"; then
    echo "not requesting ${1:0:12}: it is already on nightly-next (${promoted:0:12})"
    return 0
  fi
  if ! has_notary_gate "$1"; then
    echo "not promoting ${1:0:12}: its nightly.yml has no NIGHTLY_NEXT_NOTARY_PAUSED gate"
    return 1
  fi
  if ! strings_fresh "$1"; then
    echo "not promoting ${1:0:12}: its generated page strings are stale (node webviews/scripts/pages/gen-strings.mjs --check); an older or later commit with fresh strings is promoted"
    return 1
  fi
  if ! gh workflow run nightly.yml --repo "$repo" --ref main -f promote_nightly_next_sha="$1"; then
    echo "error: could not request the nightly-next promotion of $1" >&2
    return 2
  fi
  echo "requested nightly-next promotion of $1 (published, daemon-tested cmux-tui tree; its nightly compiles it)"
}

# 1. The tree, exactly as the nightly will resolve it. Never dispatches a
# publisher here: cmux-tui-artifacts.yml publishes every feat-cmux-next push.
if ! resolved="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CMUX_TUI_TREE_DISPATCH=0 \
    CMUX_TUI_TREE_SEARCH_COMMITS=1 bash "$script_dir/pin-cmux-tui.sh" resolve-newest-published 2>&1)"; then
  printf '%s\n' "$resolved"
  echo "not promoting ${sha:0:12}: the nightly cannot resolve a published cmux-tui tree for it yet"
  exit 0
fi
key="$(sed -n 's/^key=//p' <<<"$resolved" | head -1)"
[[ "$key" =~ ^[0-9a-f]{40}$ ]] || { printf '%s\n' "$resolved" >&2; echo "error: the resolver printed no tree key" >&2; exit 1; }

# 1b. The daemon tests passed for this tree (chief 2026-10-13). cmux-tui-artifacts
# publishes a tree before its daemon tests end; such a tree's source.json says
# daemonTests "separate", and publish-tree-tested writes daemon-tests.json when
# they pass. A tree published before that change (no field) was published only
# after its tests, as before. Missing marker: not promoted now; the artifacts
# run requests promotion again when the tests pass. Only the marker's presence
# counts: older markers carry a since-retired "os" field, newer ones do not,
# and both promote.
tree_base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}/tree/$key"
tree_meta="$(mktemp -d)"
trap 'rm -rf "$tree_meta"; cleanup_strings' EXIT
if curl -fsSL --proto '=https' --connect-timeout 20 --max-time 60 -o "$tree_meta/source.json" "$tree_base/source.json" 2>/dev/null \
   && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("daemonTests") == "separate" else 1)' "$tree_meta/source.json"; then
  if ! curl -fsSL --proto '=https' --connect-timeout 20 --max-time 60 -o "$tree_meta/daemon-tests.json" "$tree_base/daemon-tests.json" 2>/dev/null; then
    echo "not promoting ${sha:0:12}: the daemon tests have not passed for tree $key yet (no daemon-tests.json); the artifacts run requests it when they pass"
    exit 0
  fi
fi

if [[ "$mode" == release-compile-green ]]; then
  rc=0
  request "$sha" || rc=$?
  [[ "$rc" != 2 ]] || exit 1
  exit 0
fi

# 2. --tree-ready: the newest feat-cmux-next commit, by first-parent history,
# that descends from nightly-next and has this tree key, whatever its Release
# compile says (above). Candidates come from git, not from cmux-next.yml push
# runs: a push that started no run (a bot or GITHUB_TOKEN push such as a base
# autofix, or a commit outside cmux-next.yml's paths) is a candidate like any
# other, and the run list proved nothing more than "on feat-cmux-next", which
# the fetched branch does. Newest first; promotion only moves forward. The
# lower bound is nightly-next, not <sha>: the tree's publisher can be newer
# than an earlier commit with the same tree (2026-10-14), and that commit must
# not be lost. Without nightly-next in this history the bound falls back to
# <sha>. One fetch of the branch's recent history covers every candidate (a
# fetch per commit took over 5 minutes in run 37820762809). Depth-limited
# only in a shallow checkout: in a full clone --depth writes .git/shallow and
# truncates history for every worktree sharing it. When the fetch fails, the
# local feat-cmux-next branch, else <sha> alone, is the history.
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth="$((window * 4))")
tip=""
if git fetch -q --no-tags ${depth[@]+"${depth[@]}"} origin refs/heads/feat-cmux-next 2>/dev/null; then
  tip="$(git rev-parse FETCH_HEAD)"
else
  echo "warning: could not fetch feat-cmux-next; considering only local commits" >&2
  tip="$(git rev-parse --verify -q refs/heads/feat-cmux-next^{commit} 2>/dev/null || true)"
fi
[[ -n "$tip" ]] || tip="$sha"
lower="$sha"
if [[ -n "$promoted" ]] && git cat-file -e "$promoted^{commit}" 2>/dev/null; then
  lower="$promoted"
fi
refused=0
max_refused="${CMUX_NIGHTLY_NEXT_MAX_REFUSED:-5}"
[[ "$max_refused" =~ ^[1-9][0-9]?$ ]] || { echo "error: CMUX_NIGHTLY_NEXT_MAX_REFUSED must be 1 to 99" >&2; exit 2; }
while read -r run_sha; do
  [[ "$run_sha" =~ ^[0-9a-f]{40}$ ]] || continue
  if [[ "$run_sha" != "$sha" ]]; then
    git merge-base --is-ancestor "$lower" "$run_sha" 2>/dev/null || continue
    if run_key="$(python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "$run_sha" 2>/dev/null)"; then
      :
    else
      key_rc=$?
      # Exit 127 means the helper itself could not be launched. Treat that as
      # an operational failure; skipping the candidate would let this job go
      # green while never requesting the promotion it is meant to.
      if (( key_rc == 127 )); then
        echo "error: cannot compute the cmux-tui tree key for $run_sha (python3 or the key helper is unavailable)" >&2
        exit 1
      fi
      continue
    fi
    [[ "$run_key" == "$key" ]] || continue
  fi
  has_notary_gate "$run_sha" || continue
  rc=0
  request "$run_sha" || rc=$?
  [[ "$rc" != 0 ]] || exit 0
  [[ "$rc" != 2 ]] || exit 1
  # Not promotable: try the next older commit with this tree, a bounded number of times.
  refused=$((refused + 1))
  if (( refused >= max_refused )); then
    echo "not promoting: the $refused newest commits with tree $key are not promotable (see above)"
    exit 0
  fi
done < <({ git rev-list --first-parent -n "$window" "$tip" ^"$lower" 2>/dev/null || true; echo "$sha"; } | awk '!seen[$0]++')
echo "not promoting: no recent feat-cmux-next push with tree $key is promotable yet"
