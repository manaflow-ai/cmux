#!/usr/bin/env bash
# Ask main's nightly.yml (job promote-nightly-next) to move nightly-next to a
# feat-cmux-next commit, but only once that commit is buildable as a nightly:
#   1. its cmux-tui tree is published (verified the way the nightly resolves
#      it: pin-cmux-tui.sh resolve-newest-published, limited to one commit), and
#   2. it is a feat-cmux-next push (a cmux-next.yml push run exists for it).
#      From 2026-10-26 to 2026-11-25 its Release compile was not awaited (Leo:
#      "SKIP THE OLD FUCKING NIGHTLY BUILDS THEN WE'RE JSUT BUILDING FROM THE
#      TIP"), so a tip that did not compile went through the whole nightly.
#      Since 2026-11-25 the build fleet's tip check must have compiled it (or an
#      ancestor with the same app) in Release: the precheck (precheck() below)
#      is one read of a verdict that already exists, and
#   3. its generated page strings are fresh (gen-strings --check, on the commit
#      requested; a stale one is passed over for an older green one). Since
#      #21946 the tables are build output: a commit that no longer tracks them
#      passes when they generate (no translation missing).
# Both finish asynchronously, so each side asks when its half completes:
#
#   --sha <sha> --release-compile-green
#       cmux-next.yml, after the Release compile of <sha> passed. If its tree is
#       published, searches like --tree-ready: it requests the newest
#       feat-cmux-next commit with that tree, never <sha> itself once a newer
#       one has it, and nothing once nightly-next contains them. A compile that
#       finished hours late used to request its own old commit (04:41Z for a
#       00:30Z landing on 2026-10-27), which main's promote job then refused.
#       Otherwise the artifacts side asks later.
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
# An older tree (Leo, 2026-11-26: "man the tui thing is always so flakey / cant we just accept the nightly
# using an older tui version"): a commit whose own tree is a confirmed 404, with no run building it, is still
# promoted when scripts/cmux-next/older-tree-for-tip.sh finds the newest published tree within 24 h whose
# daemon-capabilities.json matches, and the commit's nightly.yml carries NIGHTLY_NEXT_TREE_AT_INSTALL (main's
# promote guard admits its missing marker on that line) and that script (its nightly builds its app with that
# tree: scripts/ci/nightly-steps/resolve-cmux-tui-client-commit.sh). The same question in both places, so
# promotion never stalls on the tui publisher (2026-11-25: none published from about 21:24Z, 108 refused).
#
# Usage: request-nightly-next.sh --repo <owner/repo> (--sha <sha> --release-compile-green | --tree-ready <sha>)
# Run from a checkout whose HEAD is <sha>. Needs GH_TOKEN with actions: write.
# Exit 0 when a commit was requested or
# none is ready yet, 2 on bad usage, 1 on an API failure.
# Env: CMUX_NIGHTLY_NEXT_RUN_WINDOW (default 99) recent first-parent commits searched;
# CMUX_NIGHTLY_NEXT_MAX_REFUSED (default 5) unpromotable candidates passed over
# (precheck refusals are not counted); NIGHTLY_NEXT_PRECHECK=0 turns the precheck off;
# CMUX_NIGHTLY_NEXT_PRECHECK_DEPTH (default 30) ancestors it reads;
# NIGHTLY_NEXT_PROMOTE=1 dispatches the promotion. Only main's 30-minute
# nightly-next-tick.yml sets it: every promotion starts a full nightly build, and
# when each landing promoted, six ran at once (2026-10-28). Without it the script
# runs every check and reports the commit it would promote, and the tick
# promotes it within 30 minutes.
set -euo pipefail

sha="" repo="" mode=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) sha="${2:-}"; shift 2 ;;
    --tree-ready) sha="${2:-}"; mode=tree-ready; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --release-compile-green) mode=release-compile-green; shift ;;
    -h|--help) sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d'; exit 0 ;;
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
    [[ "$1" == "$head" ]] || cleanup_strings
    # No node proves nothing about the strings: the run that promotes
    # (NIGHTLY_NEXT_PROMOTE=1) fails instead of requesting unchecked strings.
    if [[ "${NIGHTLY_NEXT_PROMOTE:-}" == 1 ]]; then
      echo "error: no node on this runner; the page strings of ${1:0:12} cannot be checked, so it is not promoted" >&2
      return 2
    fi
    echo "warning: no node on this runner; the page strings of ${1:0:12} are not checked" >&2
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
# One read gives nightly-next and the commit its feed last published (the publish moves the
# nightly-next tag to it, scripts/ci/update-release-tag.py): no second round trip.
# origin_git <git args...>: one bounded read of origin (ls-remote or fetch).
# The tick's checkout keeps no credentials, so these reads went to github.com
# anonymously, and GitHub held anonymous smart-HTTP reads 50-107 s before its
# first byte (measured 2026-11-25), while the same read with a token answered
# in 2-5 s. Tick 45696501186 spent 29 minutes refusing 35 commits, with gaps
# of 60-215 s, three such reads per commit. So GH_TOKEN goes along as an
# Authorization header, through git's environment config (never argv), only to
# https://github.com/ and only when the checkout has no header of its own.
# A read with a token stalled too, once in eight (cut at 30 s, its retry took
# 4 s), so each attempt is cut at CMUX_NIGHTLY_NEXT_GIT_SECONDS (default 15; a
# fetch, CMUX_NIGHTLY_NEXT_FETCH_SECONDS, default 60) and a failed attempt is
# tried again, three attempts in all (without the token after a failure that
# was not the cut, in case the token is what failed).
origin_git() {
  local secs="${CMUX_NIGHTLY_NEXT_GIT_SECONDS:-15}" url auth="" _ rc=0 out
  [[ "$1" == fetch ]] && secs="${CMUX_NIGHTLY_NEXT_FETCH_SECONDS:-60}"
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "${GH_TOKEN:-}" && "$url" == https://github.com/* ]] \
      && ! git config --get-regexp '^http\..*\.extraheader$' >/dev/null 2>&1; then
    auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  fi
  local -a cut=()
  command -v timeout >/dev/null 2>&1 && cut=(timeout -k 5 "$secs")
  for _ in 1 2 3; do
    rc=0
    out="$(
      export GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME="$secs"
      if [[ -n "$auth" ]]; then
        n="${GIT_CONFIG_COUNT:-0}"
        export GIT_CONFIG_COUNT=$((n + 1)) "GIT_CONFIG_KEY_$n=http.https://github.com/.extraheader" "GIT_CONFIG_VALUE_$n=$auth"
      fi
      ${cut[@]+"${cut[@]}"} git "$@"
    )" || rc=$?
    if (( rc == 0 )); then
      [[ -z "$out" ]] || printf '%s\n' "$out"
      return 0
    fi
    (( rc == 124 || rc == 137 )) || auth=""
  done
  return "$rc"
}
# origin_refs: nightly-next (branch and tag) and the feat-cmux-next tip in one
# read. The tick (GH_TICK_CACHE set) walks up to 120 commits, each a call of
# this script: the first call's read is kept for the whole tick, so a walk over
# many commits reads origin once, not three times a commit. A failed read is
# never kept. The tick decides in minutes, and a branch that moves meanwhile is
# the next tick's (the tick also reads the branch once, when it checks it out).
origin_refs() {
  local file="" out
  if [[ -n "${GH_TICK_CACHE:-}" ]]; then
    file="$GH_TICK_CACHE/origin-refs"
    [[ -s "$file" ]] && { cat "$file"; return 0; }
  fi
  out="$(origin_git ls-remote origin refs/heads/nightly-next refs/tags/nightly-next 'refs/tags/nightly-next^{}' refs/heads/feat-cmux-next 2>/dev/null)" || return 1
  if [[ -n "$file" && -n "$out" ]] && mkdir -p "$GH_TICK_CACHE" 2>/dev/null; then
    printf '%s\n' "$out" > "$file.$$" && mv "$file.$$" "$file"
  fi
  printf '%s\n' "$out"
}
promoted="" promoted_unknown="" published="" origin_tip=""
if refs="$(origin_refs)"; then
  while read -r oid ref; do
    [[ "$oid" =~ ^[0-9a-f]{40}$ ]] || continue
    case "$ref" in
      refs/heads/feat-cmux-next) origin_tip="$oid" ;;
      refs/heads/nightly-next) promoted="$oid" ;;
      refs/tags/nightly-next) [[ -n "$published" ]] || published="$oid" ;;
      'refs/tags/nightly-next^{}') published="$oid" ;;  # an annotated tag's commit
    esac
  done <<<"$refs"
else
  promoted_unknown=1
fi
already_promoted() { # <sha>
  # Equality needs no history: cmux-next.yml checks out one commit.
  [[ -n "$promoted" ]] || return 1
  [[ "$1" != "$promoted" ]] || return 0
  git cat-file -e "$promoted^{commit}" 2>/dev/null && git merge-base --is-ancestor "$1" "$promoted" 2>/dev/null
}

# app_unchanged <sha>: 0 when nothing that can change the app the nightly publishes changed
# between the published commit and <sha>, by scripts/ci/nightly_build_inputs.py (the classifier
# main's nightly skips with: the cmux-next target and what it bundles, the cmux-tui client paths,
# and every path the nightly workflow runs). Such a promotion builds and publishes the same app
# again: of 92 NEXT nightlies published 2026-11-01/02 only 3 were app-identical, but each costs a
# full build, signing and two notarizations. Any doubt (no published commit, history too shallow,
# not a descendant, an unreadable classifier, a different cmux-tui tree key) answers 1, and the
# commit is promoted.
app_unchanged_reason=""
# same_app <base> <sha>: 0 when nothing that reaches the app changed from <base> to <sha>.
same_app() { # <base> <sha>
  git cat-file -e "$1^{commit}" 2>/dev/null || return 1
  git merge-base --is-ancestor "$1" "$2" 2>/dev/null || return 1
  [[ -f "$repo_root/scripts/ci/nightly_build_inputs.py" ]] || return 1
  local files verdict
  files="$(git diff --no-renames --name-only "$1" "$2")" || return 1  # a move out of the app names its old path too
  if [[ -z "$files" ]]; then
    app_unchanged_reason="the same tree"
    return 0
  fi
  verdict="$(printf '%s\n' "$files" | python3 "$repo_root/scripts/ci/nightly_build_inputs.py" --files-from - 2>/dev/null)" || return 1
  [[ "$verdict" == *'"build_inputs_changed": false'* ]] || return 1
  # The classifier does not see every input of the bundled cmux-tui binaries (workers/cmux-vm/cli,
  # skills/cmux-browser are tree inputs it calls neutral): the tree key must match too. Read only
  # here, after the classifier found nothing, so an app change pays nothing for it.
  local key_base key_sha
  key_base="$(python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "$1" 2>/dev/null)" || return 1
  key_sha="$(python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "$2" 2>/dev/null)" || return 1
  [[ "$key_base" =~ ^[0-9a-f]{40}$ && "$key_base" == "$key_sha" ]] || return 1
  app_unchanged_reason="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["reason"])' "$verdict" 2>/dev/null || echo unchanged)"
}
app_unchanged() { # <sha>
  app_unchanged_reason=""
  [[ -n "$published" && "$published" != "$1" ]] || return 1
  same_app "$published" "$1" || return 1
  # A promotion still building (nightly-next past the published commit) publishes its own app
  # next: <sha> must match that one too, or a revert of it would wait for it to publish first.
  if [[ -n "$promoted" && "$promoted" != "$published" ]] \
     && ! git merge-base --is-ancestor "$promoted" "$published" 2>/dev/null; then
    local reason="$app_unchanged_reason"
    same_app "$promoted" "$1" || return 1
    app_unchanged_reason="$reason"
  fi
}

# The precheck (Leo, 2026-11-25: "isn't there a way to precheck a nightly before it goes through
# alllllll the steps?"): a commit is promoted only once the build fleet's tip check has compiled its
# app in Release, so a nightly never starts its Mac build, signing and notarization on a commit that
# does not compile. nightly-next 4b7d1bfb618a (2026-11-25 03:31) was promoted while its tip check was
# red. The verdict already exists when the tick asks: the controller compiles every feat-cmux-next push
# tip (cmux_next_tip_check.go) and the results service serves it (fleet_compile_result.py reads the
# same record), so the precheck is one read, not a compile. It selects a commit and blocks no merge:
# a commit with no verdict of its own is passed over for an older one that has one, as a stale-strings
# commit is.
#   pass   its own record passed, or the nearest first-parent ancestor with a verdict passed and
#          nothing that reaches the app changed since (same_app: the nightly's input classifier and
#          the cmux-tui tree key), so the same app compiled;
#   red    that verdict failed;
#   covered  its record is superseded (the controller checked a newer push tip instead, and that check
#          covers this push's commits) and the first checked tip after it passed. Most feat-cmux-next
#          commits are superseded, and the tree publisher also keeps only one push per window, so
#          requiring both on the same commit left the dedicated Macs idle for hours with commits waiting
#          (11-25: 77, 132 and 100+ minute gaps, every tick "N refused"; Leo, 2026-11-25: "Just keep
#          the train going like 24/7, constantly"). A commit between it and that tip could have fixed
#          its compile; then its nightly fails at the Mac build, which the next commit replaces;
#   none   no verdict yet (queued, never checked, or superseded by a tip not checked yet or red): an
#          older commit is tried, and the next tick tries this one again;
#   down   the results service did not answer: promoted as before, with a warning (the feed must not
#          stop on an outage of a cache).
# NIGHTLY_NEXT_PRECHECK=0 turns it off. CMUX_NIGHTLY_NEXT_PRECHECK_DEPTH (default 30) ancestors are read
# at most; each verdict is read once a tick (the tick runs this script once per commit it walks).
precheck_results="${CMUX_NIGHTLY_NEXT_PRECHECK_RESULTS:-https://gh-events.cmux.com/compile-checks/v1}"
precheck_reason=""
# fleet_verdict <sha>: pass, fail, pending, superseded (a newer push tip's check covers it), none (no
# usable record) or down.
fleet_verdict() { # <sha>
  local cache="" body code word
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    cache="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nightly-next-precheck-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}"
    mkdir -p "$cache" 2>/dev/null || cache=""
    if [[ -n "$cache" && -s "$cache/$1" ]]; then cat "$cache/$1"; return 0; fi
  fi
  body="$(mktemp "${TMPDIR:-/tmp}/nightly-next-precheck.XXXXXX")"
  # The default read only: a phase= read submits a build (cmuxterm-hq handbook, scheme-debug).
  # The compile-results CDN rejects curl's default user agent (handbook
  # cdn-refuses-the-default-client). Keep this read aligned with
  # scripts/ci/fleet_compile_result.py so a valid verdict is not mistaken for
  # an outage and an unchecked nightly is not promoted.
  code="$(curl -sS -A 'cmux-ci-fleet-compile-result/1' -o "$body" -w '%{http_code}' --connect-timeout 10 --max-time 20 \
    "$precheck_results/$1?repo=${repo/\//%2F}" 2>/dev/null)" || code="${code:-000}"
  case "$code" in
    200) word="$(python3 -I -c '
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("none"); sys.exit()
if not isinstance(r, dict) or r.get("sha") != sys.argv[2] or r.get("repo") != sys.argv[3] \
        or r.get("recipe_version") != 2 or r.get("configuration") != "release-onone":
    print("none")
elif r.get("state") in ("pass", "fail"):
    print(r["state"])
elif r.get("state") in ("queued", "running", "deferred", "", None):
    print("pending")
elif r.get("state") == "superseded":
    print("superseded")
else:
    print("none")
' "$body" "$1" "$repo" 2>/dev/null)" || word=none ;;
    404) word=none ;;
    # Busy answers mean the service is reachable but has no stable verdict for
    # this tick. Wait for the next tick instead of treating them as a cache
    # outage and promoting an unchecked commit.
    429|503) word=pending ;;
    *) word=down ;;
  esac
  rm -f "$body"
  # Only a verdict is kept: a pending or missing one may be there on the next read.
  [[ -z "$cache" || ! "$word" =~ ^(pass|fail)$ ]] || printf '%s\n' "$word" > "$cache/$1"
  echo "$word"
}
# precheck <sha>: 0 = pass (or down, or off), 1 = red, 3 = no verdict yet. Sets precheck_reason.
precheck() { # <sha>
  precheck_reason=""
  [[ "${NIGHTLY_NEXT_PRECHECK:-1}" != 0 ]] || { precheck_reason="the precheck is off (NIGHTLY_NEXT_PRECHECK=0)"; return 0; }
  local word ancestor depth="${CMUX_NIGHTLY_NEXT_PRECHECK_DEPTH:-30}" saved="$app_unchanged_reason"
  [[ "$depth" =~ ^[0-9]+$ ]] || depth=30
  word="$(fleet_verdict "$1")"
  case "$word" in
    pass) precheck_reason="the build fleet compiled it in Release"; return 0 ;;
    fail) precheck_reason="the build fleet's Release compile of it failed"; return 1 ;;
    down)
      echo "::warning title=nightly-next precheck::the compile results service did not answer for ${1:0:12}; promoting it unprechecked" >&2
      precheck_reason="the results service did not answer, so it is not prechecked"
      return 0 ;;
    superseded)
      # The check that covers it is the first checked push tip after it on feat-cmux-next.
      local later
      while read -r later; do
        [[ "$later" =~ ^[0-9a-f]{40}$ ]] || continue
        word="$(fleet_verdict "$later")"
        case "$word" in
          pass)
            precheck_reason="its push was superseded by ${later:0:12}, whose Release compile on the build fleet covers it and passed"
            return 0 ;;
          fail|pending|down) break ;;
        esac
      done < <(git rev-list --first-parent --ancestry-path --reverse "$1..${tip:-$1}" 2>/dev/null | head -n "$depth")
      ;;
  esac
  # No verdict of its own: the nearest ancestor with one stands for it when the app is the same.
  while read -r ancestor; do
    [[ "$ancestor" =~ ^[0-9a-f]{40}$ ]] || continue
    word="$(fleet_verdict "$ancestor")"
    [[ "$word" == pass || "$word" == fail ]] || continue
    if ! same_app "$ancestor" "$1"; then
      app_unchanged_reason="$saved"
      precheck_reason="no Release compile verdict for it yet (the nearest one, ${ancestor:0:12}, compiled another app)"
      return 3
    fi
    app_unchanged_reason="$saved"
    if [[ "$word" == pass ]]; then
      precheck_reason="the build fleet compiled ${ancestor:0:12} in Release, and nothing that reaches the app changed since"
      return 0
    fi
    precheck_reason="the build fleet's Release compile of ${ancestor:0:12} failed, and nothing that reaches the app changed since"
    return 1
  done < <(git rev-list --first-parent -n "$depth" "$1^" 2>/dev/null)
  precheck_reason="no Release compile verdict for it or the ancestors read yet"
  return 3
}

# request <sha>: 0 = requested or already on nightly-next, 1 = not promotable
# (no gate, stale strings), 2 = the dispatch itself failed (an API error) or
# the promoting run has no node to check the strings with (the caller exits 1).
request() { # <sha>
  if already_promoted "$1"; then
    echo "not requesting ${1:0:12}: it is already on nightly-next (${promoted:0:12})"
    return 0
  fi
  # The tick's walk stops on "already on nightly-next": an older commit changes even less.
  if app_unchanged "$1"; then
    echo "not requesting ${1:0:12}: nothing that reaches the app changed since the published ${published:0:12} ($app_unchanged_reason), so its app is already on nightly-next"
    return 0
  fi
  if ! has_notary_gate "$1"; then
    echo "not promoting ${1:0:12}: its nightly.yml has no NIGHTLY_NEXT_NOTARY_PAUSED gate"
    return 1
  fi
  # The precheck, before anything that costs more (the strings check checks out a worktree).
  local precheck_rc=0
  precheck "$1" || precheck_rc=$?
  if (( precheck_rc == 1 )); then
    echo "not promoting ${1:0:12}: precheck red: $precheck_reason; an older commit that compiles is promoted"
    precheck_refused=1
    return 1
  elif (( precheck_rc != 0 )); then
    echo "not promoting ${1:0:12}: not prechecked yet: $precheck_reason; an older prechecked commit is promoted, and the next tick asks again"
    precheck_refused=1
    return 1
  fi
  echo "precheck ${1:0:12}: $precheck_reason"
  local strings_rc=0
  strings_fresh "$1" || strings_rc=$?
  (( strings_rc != 2 )) || return 2
  if (( strings_rc != 0 )); then
    echo "not promoting ${1:0:12}: its generated page strings are stale (node webviews/scripts/pages/gen-strings.mjs --check); an older or later commit with fresh strings is promoted"
    return 1
  fi
  # Main's promote guard requires the tree-commit marker (the same check), so
  # a commit without one is not requested: the backfill marks it. A tip whose
  # tree is still building (request_tree_pending) is the exception main's
  # guard makes too: its nightly waits for the marker before it publishes.
  local marker_rc=0
  if [[ "${tree_pending_request:-}" == "$1" ]]; then
    echo "${1:0:12}: its tree is still building; its nightly.yml waits for it at install (NIGHTLY_NEXT_TREE_AT_INSTALL)"
  elif [[ "${tree_older_request:-}" == "$1" ]]; then
    echo "${1:0:12}: its tree is not published; its nightly builds its app with the older tree ${older_key:0:12} of ${older_from:0:12} (no marker of its own: NIGHTLY_NEXT_TREE_AT_INSTALL)"
  else
    bash "$script_dir/tree-commit-marker.sh" check "$1" >/dev/null || marker_rc=$?
  fi
  if (( marker_rc == 1 )); then
    echo "not promoting ${1:0:12}: its tree is ready but it has no tree-commit marker yet"
    backfill "${1:0:12} has a ready tree and no tree-commit marker"
    return 1
  elif (( marker_rc != 0 )); then
    echo "not promoting ${1:0:12}: read failure on its tree-commit marker (above); no backfill on a read failure"
    return 1
  fi
  if [[ "${NIGHTLY_NEXT_PROMOTE:-}" != 1 ]]; then
    echo "promotable ${1:0:12}: not requested here; the 30-minute nightly-next tick (nightly-next-tick.yml) promotes it"
    return 0
  fi
  if ! gh workflow run nightly.yml --repo "$repo" --ref main -f promote_nightly_next_sha="$1"; then
    echo "error: could not request the nightly-next promotion of $1" >&2
    return 2
  fi
  if [[ "${tree_pending_request:-}" == "$1" ]]; then
    echo "requested nightly-next promotion of $1 (its cmux-tui tree is building; its nightly compiles the app now and installs the tree's client)"
  elif [[ "${tree_older_request:-}" == "$1" ]]; then
    echo "requested nightly-next promotion of $1 (its cmux-tui tree is not published; its nightly builds its app with the older published tree ${older_key:0:12} of ${older_from:0:12}, same daemon-capabilities.json)"
  else
    echo "requested nightly-next promotion of $1 (published, verified cmux-tui tree; its nightly compiles it)"
  fi
}

# starved_runs <commit>: how many of the commit's queued cmux-tui-artifacts
# push runs have a first job that has waited past CMUX_TREE_RUN_STARVED_MIN
# (default 30) minutes with no runner. Such a run counts as no run: it is not
# building the tree, and the rescue dispatch must not wait on it (2026-11-19:
# 40+ feat-cmux-next preflights queued since 04:21Z on cmux-gcp-lane-build-x64
# with every runner busy, and no tip got its tree). Only push runs: a
# workflow_dispatch run is the rescue itself, so each tip is rescued at most
# once. A read that fails counts nothing starved (the old, careful answer).
starved_runs() { # <commit>
  local limit="${CMUX_TREE_RUN_STARVED_MIN:-30}" now ids id first at age n=0
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=30
  now="$(date -u +%s)"
  ids="$(gh api "repos/$repo/actions/workflows/cmux-tui-artifacts.yml/runs?head_sha=$1&event=push&status=queued&per_page=20" \
    --jq '.workflow_runs[].id' 2>/dev/null)" || { echo 0; return 0; }
  for id in $ids; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    # The run's first job (the oldest), and only while it is queued with no runner.
    first="$(gh api "repos/$repo/actions/runs/$id/jobs?filter=latest&per_page=100" \
      --jq '[.jobs[]] | sort_by(.created_at) | first | select(. != null and .status == "queued" and ((.runner_name // "") == "")) | .created_at' \
      2>/dev/null)" || continue
    [[ -n "$first" ]] || continue
    at="$(date -u -d "$first" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$first" +%s 2>/dev/null)" || continue
    age=$(( (now - at) / 60 ))
    if (( age >= limit )); then
      echo "cmux-tui-artifacts run $id for ${1:0:12}: its first job has waited ${age} min with no runner; counted as no run" >&2
      n=$((n + 1))
    fi
  done
  echo "$n"
}

# NIGHTLY_NEXT_TREE_AT_INSTALL: the feat-cmux-next tip whose tree is a
# confirmed 404 (never a read failure), whose own nightly.yml carries the line
# main's promote guard reads, and whose tree a cmux-tui-artifacts run is
# building now (the run of the tip or of a first-parent ancestor with the same
# key) is requested at once: its nightly compiles the app while the tree builds.
# Returns request()'s codes, or 1 when it does not apply.
request_tree_pending() {
  local tip_key verify=0 commit runs active=""
  # The tip from origin_refs: empty when that read failed, as before.
  [[ -n "$origin_tip" && "$origin_tip" == "$sha" ]] || return 1
  # The whole file first: `git show | grep -q` fails under pipefail on an early match.
  local workflow
  workflow="$(git show "$sha:.github/workflows/nightly.yml" 2>/dev/null)" || return 1
  grep -qxE '[[:space:]]*NIGHTLY_NEXT_TREE_AT_INSTALL: v1[[:space:]]*' <<<"$workflow" || return 1
  tip_key="$(python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "$sha" 2>/dev/null)" || return 1
  bash "$script_dir/pin-cmux-tui.sh" verify-key "$tip_key" >/dev/null 2>&1 || verify=$?
  (( verify == 1 )) || return 1
  while read -r commit; do
    [[ "$(python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "$commit" 2>/dev/null)" == "$tip_key" ]] || break
    runs="$(gh run list --repo "$repo" --workflow cmux-tui-artifacts.yml --commit "$commit" --limit 5 --json status \
      --jq '[.[] | select(.status != "completed")] | length' 2>/dev/null)" || continue
    # A run starved of a runner builds nothing: it must not stand for the tree.
    [[ "$runs" =~ ^[1-9][0-9]*$ ]] && runs=$((runs - $(starved_runs "$commit")))
    if [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then active="$commit"; break; fi
  done < <(git rev-list --first-parent -n 40 "$sha" 2>/dev/null)
  if [[ -z "$active" ]]; then
    echo "not requesting ${sha:0:12} before its tree: no active cmux-tui-artifacts run builds tree $tip_key"
    return 1
  fi
  echo "${sha:0:12}: tree $tip_key is building in the cmux-tui-artifacts run of ${active:0:12}"
  tree_pending_request="$sha"
  local rc=0
  request "$sha" || rc=$?
  return "$rc"
}

# request_older_tree: <sha> with an older published tree (the header's "An older tree"). Returns request()'s
# codes, or 1 when it does not apply: the commit's nightly.yml lacks the line or the script, or no tree matches.
tree_older_request="" older_key="" older_from=""
request_older_tree() {
  local workflow older
  # A tip whose tree is building already had its request (request_tree_pending).
  [[ -z "${tree_pending_request:-}" ]] || return 1
  git cat-file -e "$sha:scripts/cmux-next/older-tree-for-tip.sh" 2>/dev/null || return 1
  # The whole file first: `git show | grep -q` fails under pipefail on an early match.
  workflow="$(git show "$sha:.github/workflows/nightly.yml" 2>/dev/null)" || return 1
  grep -qxE '[[:space:]]*NIGHTLY_NEXT_TREE_AT_INSTALL: v1[[:space:]]*' <<<"$workflow" || return 1
  older="$(bash "$script_dir/older-tree-for-tip.sh")" || return 1
  older_key="$(sed -n 's/^key=//p' <<<"$older" | head -1)"
  older_from="$(sed -n 's/^tree_from=//p' <<<"$older" | head -1)"
  echo "${sha:0:12}: its own tree is not published; older tree $older_key of ${older_from:0:12} (commits, hours behind: ${older_from#* }) has its daemon-capabilities.json"
  older_from="${older_from%% *}"
  tree_older_request="$sha"
  local rc=0
  request "$sha" || rc=$?
  return "$rc"
}

# backfill <reason>: one cmux-tui-artifacts dispatch on feat-cmux-next, which
# marks every recent commit whose tree is ready (mark-tree-commits) and builds
# the tip's tree when it has none. At most one per job (the nightly-next tick
# calls this script once per commit it walks): a stamp in RUNNER_TEMP keyed by
# the run. Never while an artifacts run for the dispatch's current branch tip
# is queued, waiting or in progress (one filtered read per state, so no older
# active run hides behind newer finished ones), and never when that cannot be
# read. An unrelated tree cannot publish this tip: its run must not suppress
# recovery. request_tree_pending already reuses an active same-tree ancestor
# before a missing tree reaches this fallback. Two jobs
# racing past the check (the tick and an artifacts push run) start at most two
# runs, and a dispatch's concurrency group (one per commit, never cancelled)
# keeps one of them pending behind the other.
backfill() { # <reason>
  local stamp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-tree-backfill-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}" active
  if [[ -e "$stamp" ]]; then
    echo "backfill: already dispatched in this job; not dispatching again ($1)"
    return 0
  fi
  local state count dispatch_tip
  # This function also repairs older candidates' markers, but the dispatch
  # always builds feat-cmux-next. Bind the duplicate check to that source,
  # rather than the candidate or every publisher on the branch.
  if ! [[ "$origin_tip" =~ ^[0-9a-f]{40}$ ]]; then
    echo "backfill: could not read the feat-cmux-next tip; not dispatching ($1)"
    return 0
  fi
  dispatch_tip="$origin_tip"
  active=0
  # The REST filter, not `gh run list --status`: gh's flag refuses "pending"
  # (a run held behind its concurrency group).
  for state in queued in_progress waiting pending requested; do
    if ! count="$(gh api "repos/$repo/actions/workflows/cmux-tui-artifacts.yml/runs?branch=feat-cmux-next&head_sha=$dispatch_tip&status=$state&per_page=1" \
        --jq .total_count 2>/dev/null)" || [[ ! "$count" =~ ^[0-9]+$ ]]; then
      echo "backfill: could not read the cmux-tui-artifacts runs; not dispatching ($1)"
      return 0
    fi
    active=$((active + count))
  done
  # A tip run queued past the limit with no runner is no run (starved_runs).
  (( active > 0 )) && active=$((active - $(starved_runs "$dispatch_tip")))
  if (( active > 0 )); then
    echo "backfill: a cmux-tui-artifacts run for feat-cmux-next ${dispatch_tip:0:12} is queued or running; not dispatching ($1)"
    return 0
  fi
  # One backfill an hour, at most (ci-min-per-pr-14, Leo: "de facto, im asking for 99% fewer minutes of
  # ci time, period."). Every tick, Release compile and artifacts completion calls this, each from its own
  # job, so the per-job stamp never held: 51 dispatches on feat-cmux-next in 31 h (2026-11-24 10:10Z to
  # 2026-11-25 17:12Z), often 4-6 min apart, about 80 runner-min each (three target builds plus daemon
  # tests), for a tip that moved by a few commits. The next tick after the gap dispatches the newest tip,
  # which marks every commit the skipped ones would have. NIGHTLY_NEXT_BACKFILL_GAP_MIN=0 turns it off.
  local gap_min="${NIGHTLY_NEXT_BACKFILL_GAP_MIN:-60}" last_dispatch last_s age_min
  if [[ "$gap_min" =~ ^[0-9]+$ ]] && (( gap_min > 0 )); then
    if ! last_dispatch="$(gh api "repos/$repo/actions/workflows/cmux-tui-artifacts.yml/runs?branch=feat-cmux-next&event=workflow_dispatch&per_page=1" \
        --jq '.workflow_runs[0].created_at // ""' 2>/dev/null)"; then
      echo "backfill: could not read the last cmux-tui-artifacts dispatch; not dispatching ($1)"
      return 0
    fi
    if [[ -n "$last_dispatch" ]] && last_s="$(date -u -d "$last_dispatch" +%s 2>/dev/null \
        || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_dispatch" +%s 2>/dev/null)"; then
      age_min=$(( ($(date -u +%s) - last_s) / 60 ))
      if (( age_min < gap_min )); then
        echo "backfill: the last cmux-tui-artifacts dispatch on feat-cmux-next was ${age_min} min ago (gap ${gap_min} min); not dispatching ($1)"
        return 0
      fi
    fi
  fi
  if gh workflow run cmux-tui-artifacts.yml --repo "$repo" --ref feat-cmux-next; then
    : > "$stamp"
    echo "backfill: dispatched cmux-tui-artifacts on feat-cmux-next ($1)"
  else
    echo "warning: backfill: could not dispatch cmux-tui-artifacts on feat-cmux-next ($1)" >&2
  fi
}

# 1. The tree, exactly as the nightly will resolve it. Never dispatches a
# publisher here: cmux-tui-artifacts.yml publishes every feat-cmux-next push.
if ! resolved="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY CMUX_TUI_TREE_DISPATCH=0 \
    CMUX_TUI_TREE_SEARCH_COMMITS=1 bash "$script_dir/pin-cmux-tui.sh" resolve-newest-published 2>&1)"; then
  printf '%s\n' "$resolved"
  pending_rc=0
  request_tree_pending || pending_rc=$?
  case "$pending_rc" in
    0) exit 0 ;;
    2) exit 1 ;;
  esac
  older_rc=0
  request_older_tree || older_rc=$?
  case "$older_rc" in
    0) exit 0 ;;
    2) exit 1 ;;
  esac
  echo "not promoting ${sha:0:12}: the nightly cannot resolve a published cmux-tui tree for it yet"
  # The feat-cmux-next tip with no cmux-tui-artifacts run at all (a push that
  # started none, such as a GITHUB_TOKEN push) gets one, and so does a tip whose
  # only runs are push runs starved of a runner past the limit (starved_runs). A
  # tip whose run failed or is running gets none: a failed build is a red to
  # fix, not to re-run here. A run that succeeded while the tip's tree is a
  # confirmed 404 built nothing (a coalesced or superseded push: base-coalesce
  # lets one feat-cmux-next push per window build), so it counts as no run.
  # Without that, the tick walked past every coalesced tip to the window's
  # older built commit: on 2026-11-23 it cut commits 40-87 min old. The
  # dispatched build is then the tip's active run, so the next tick requests
  # the tip with NIGHTLY_NEXT_TREE_AT_INSTALL.
  # A green workflow_dispatch run (this backfill's own build) still counts:
  # if it published nothing, re-dispatching it every tick would not help.
  # Only on a confirmed miss: the CDN answers 404 for the tip's tree (verify-key
  # exit 1), never on a read failure.
  if [[ -n "$origin_tip" && "$origin_tip" == "$sha" ]] \
      && tip_key="$(python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "$sha" 2>/dev/null)"; then
    tip_verify=0
    bash "$script_dir/pin-cmux-tui.sh" verify-key "$tip_key" >/dev/null 2>&1 || tip_verify=$?
    if (( tip_verify == 1 )) \
        && tip_runs="$(gh run list --repo "$repo" --workflow cmux-tui-artifacts.yml --commit "$sha" --limit 5 --json status,conclusion,event \
             --jq '[.[] | select(.status != "completed" or .conclusion != "success" or .event == "workflow_dispatch")] | length' 2>/dev/null)" \
        && [[ "$tip_runs" =~ ^[0-9]+$ ]] \
        && { (( tip_runs == 0 )) || (( tip_runs - $(starved_runs "$sha") <= 0 )); }; then
      backfill "the feat-cmux-next tip ${sha:0:12} has no cmux-tui-artifacts run"
    fi
  fi
  exit 0
fi
key="$(sed -n 's/^key=//p' <<<"$resolved" | head -1)"
[[ "$key" =~ ^[0-9a-f]{40}$ ]] || { printf '%s\n' "$resolved" >&2; echo "error: the resolver printed no tree key" >&2; exit 1; }

# The tree's daemon tests are not awaited (2026-10-28, tree-commit-marker.sh's
# header): they run after the publish and report on their own, and a failed
# download in them held the feed for hours. Leo, 2026-10-23: "we want no smoke
# tests".

# 2. Both modes: the newest feat-cmux-next commit, by first-parent history,
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
# In the tick (GH_TICK_CACHE) the first fetch's tip is kept: the walk's later
# calls share the repository it deepened, so they fetch nothing again.
tip="" fetched_file=""
[[ -n "${GH_TICK_CACHE:-}" ]] && fetched_file="$GH_TICK_CACHE/feat-cmux-next-fetched"
if [[ -n "$fetched_file" && -s "$fetched_file" ]] && tip="$(cat "$fetched_file")" \
    && [[ "$tip" =~ ^[0-9a-f]{40}$ ]] && git cat-file -e "$tip^{commit}" 2>/dev/null; then
  :
elif tip="" && origin_git fetch -q --no-tags ${depth[@]+"${depth[@]}"} origin refs/heads/feat-cmux-next 2>/dev/null; then
  tip="$(git rev-parse FETCH_HEAD)"
  if [[ -n "$fetched_file" ]] && mkdir -p "$GH_TICK_CACHE" 2>/dev/null; then
    printf '%s\n' "$tip" > "$fetched_file.$$" && mv "$fetched_file.$$" "$fetched_file"
  fi
else
  echo "warning: could not fetch feat-cmux-next; considering only local commits" >&2
  tip="$(git rev-parse --verify -q refs/heads/feat-cmux-next^{commit} 2>/dev/null || true)"
fi
[[ -n "$tip" ]] || tip="$sha"
lower="$sha"
if [[ -n "$promoted" ]] && git cat-file -e "$promoted^{commit}" 2>/dev/null; then
  lower="$promoted"
fi
# <sha> itself is the last candidate. After a Release compile it is requested
# only when it provably descends from nightly-next: a compile that finished
# late, beyond this history's reach, must not ask for its old commit (main's
# promote job would refuse it as behind nightly-next).
# After a Release compile, nothing is requested unless nightly-next was read:
# without it no candidate is provably ahead of it.
if [[ "$mode" == release-compile-green && -n "$promoted_unknown" ]]; then
  echo "not requesting: could not read nightly-next from origin; the tree side asks"
  exit 0
fi
if [[ "$mode" == release-compile-green && -n "$promoted" ]] && ! git cat-file -e "$promoted^{commit}" 2>/dev/null; then
  echo "not requesting: nightly-next (${promoted:0:12}) is not in this history, so no candidate is provably ahead of it; the tree side asks"
  exit 0
fi
fallback="$sha"
if [[ "$mode" == release-compile-green && -n "$promoted" ]] \
   && ! git merge-base --is-ancestor "$promoted" "$sha" 2>/dev/null; then
  fallback=""
fi
refused=0
quarantine_read="" quarantined_list=""
max_refused="${CMUX_NIGHTLY_NEXT_MAX_REFUSED:-5}"
[[ "$max_refused" =~ ^[1-9][0-9]?$ ]] || { echo "error: CMUX_NIGHTLY_NEXT_MAX_REFUSED must be 1 to 99" >&2; exit 2; }
while read -r run_sha; do
  [[ "$run_sha" =~ ^[0-9a-f]{40}$ ]] || continue
  # <sha> without its ancestry proof (above) is never requested, even when the
  # history lists it (a merge can bring nightly-next in beside it).
  [[ "$run_sha" != "$sha" || -n "$fallback" ]] || continue
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
  # <sha> itself goes to request(), which names a missing gate.
  [[ "$run_sha" == "$sha" ]] || has_notary_gate "$run_sha" || continue
  # A commit the direct-push quarantine holds (scripts/cmux-next/nightly_quarantine.py: cmuxterm-hq's base-red-watch
  # found a direct push red on feat-cmux-next's push runs and no later push green) is never promoted: nightly-next
  # stays on its last build and skips forward once a fix or revert passes. Read once a run, on the first candidate
  # that gets this far; unreadable, nothing is held (base-red-watch still pages the base-reds owner).
  if [[ -z "$quarantine_read" ]]; then
    quarantine_read=1
    if ! quarantined_list="$(python3 "$repo_root/scripts/cmux-next/nightly_quarantine.py" quarantined --repo "$repo" --tip "$tip" 2>/dev/null)"; then
      echo "warning: the direct-push quarantine is unreadable; promoting as if none were open" >&2
      quarantined_list=""
    fi
  fi
  if held_by="$(grep -m1 "^$run_sha " <<<"$quarantined_list")"; then
    read -r _ q_culprit q_pusher <<<"$held_by"
    echo "not promoting ${run_sha:0:12}: quarantined since direct push $q_culprit by $q_pusher failed the direct-push gates; a later push that passes them (a fix or a revert) is promoted"
    continue
  fi
  rc=0 precheck_refused=""
  request "$run_sha" || rc=$?
  [[ "$rc" != 0 ]] || exit 0
  [[ "$rc" != 2 ]] || exit 1
  # Not promotable: try the next older commit with this tree, a bounded number of times. A precheck
  # refusal costs one read and is not counted: the newest prechecked commit can be dozens of
  # landings back, and the tick passes over every other commit with this tree.
  [[ -z "$precheck_refused" ]] || continue
  refused=$((refused + 1))
  if (( refused >= max_refused )); then
    echo "not promoting: the $refused newest commits with tree $key are not promotable (see above)"
    exit 0
  fi
done < <({ git rev-list --first-parent -n "$window" "$tip" ^"$lower" 2>/dev/null || true; [[ -z "$fallback" ]] || echo "$fallback"; } | awk '!seen[$0]++')
echo "not promoting: no recent feat-cmux-next push with tree $key is promotable yet"
