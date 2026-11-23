#!/usr/bin/env bash
# Lands base autofix's repair (HEAD, one commit on top of BASE_SHA) on BRANCH of REMOTE, and keeps
# landing it while the branch moves (cmux-next-base-autofix.yml's Push the repairs step).
#
# base-autofix-push.sh lands what is still right on the newest tip and holds a file whose inputs
# the tip moved since it was made. When it holds a file this job can make itself (the CI target
# graph, the SDK layers, the namespace ratchet, the cloud clients, cargo fmt), this checks out the
# new tip, makes the repair again there (CMUX_BASE_AUTOFIX_REPAIR with CMUX_BASE_AUTOFIX_AGAIN=1),
# commits it as made at that tip, and pushes that, up to CMUX_BASE_AUTOFIX_ROUNDS rounds in all (3).
# Any Packages/ change moves the graph's inputs, and feat-cmux-next takes one every minute or two,
# so a held graph waiting for the next run was held again there (every run from 08:58 to 10:00 on
# 2026-10-21).
#
# The Mac exports (the action and settings exports) are never made here: a held one waits for the
# next run's Mac job, and the run fails, so the next run's "since" still covers it. What is built
# from the action exports (the docs shortcuts, the app-host files) is made again on the tip from the
# exports there when this run made them (ACTIONS_MADE_AT) and none was held: the tip then holds this
# run's exports, or a newer commit's own copy (base-autofix-push.sh lands them as progress past a
# move of their inputs), and the checks compare the built files with the exports committed beside them. The defaults snapshot, which reads
# both exports, and the settings docs reference are made again the same way when this run made the
# settings exports (SETTINGS_MADE_AT) and none was held (they landed, as progress past a move of their
# inputs too); without SETTINGS_MADE_AT only when the tip's sources give the same source stamp
# (defaults_guard.py source-stamp, derived from each tree; the stamp is never committed) as BASE_SHA,
# whose committed exports the first push built the snapshot from. Otherwise,
# and for the webviews formatting, a held file waits for the next run and the run fails.
# A round that finds nothing left to repair on the tip ends the run.
#
# The repair runs without TOKEN, the push credentials; only base-autofix-push.sh gets them.
#
# Usage: scripts/cmux-next/base-autofix-land.sh REMOTE BRANCH BASE_SHA [SETTINGS_MADE_AT] [ACTIONS_MADE_AT]
# TOKEN: the push token (unset: the caller's git credentials). RUN_URL: named in a new commit.
# CMUX_BASE_AUTOFIX_REPAIR: the repair, run as `REPAIR REPO` (default: base-autofix-repair.sh).
# CMUX_BASE_AUTOFIX_PUSH: the push (default: base-autofix-push.sh beside this one).
set -euo pipefail

# The whole body is read before it runs: a checkout of a newer tip rewrites this file.
main() {
  remote="${1:?usage: $0 REMOTE BRANCH BASE_SHA [SETTINGS_MADE_AT] [ACTIONS_MADE_AT]}"
  branch="${2:?usage: $0 REMOTE BRANCH BASE_SHA [SETTINGS_MADE_AT] [ACTIONS_MADE_AT]}"
  base="${3:?usage: $0 REMOTE BRANCH BASE_SHA [SETTINGS_MADE_AT] [ACTIONS_MADE_AT]}"
  settings_made_at="${4:-}"
  actions_made_at="${5:-}"
  actions_current=0 settings_current=0
  action_exports='^plans/cmux-next/(action-surfaces\.json|action-catalog\.json|actions\.md|links\.json)$'
  # From scripts/cmux-next/settings-exports.txt, the one list of what the settings export writes,
  # so this does not become a fourth hand-kept copy of it (review of #23915).
  local settings_alternation
  settings_alternation="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[.]/[.]/g' \
    "$(dirname "${BASH_SOURCE[0]}")/settings-exports.txt" | paste -sd'|' -)"
  # An empty list would give `^()$`, which matches the empty string and nothing else: every export
  # would silently look unrelated to the settings area instead of failing here.
  [[ -n "$settings_alternation" ]] || {
    echo "::error::scripts/cmux-next/settings-exports.txt lists no export" >&2
    exit 1
  }
  settings_exports="^($settings_alternation)$"
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/cmux-next/lib/origin-net.sh
  source "$here/lib/origin-net.sh"
  rounds="${CMUX_BASE_AUTOFIX_ROUNDS:-3}"
  token="${TOKEN:-}"
  unset TOKEN
  # The Swift rewrites' pull request only: the push token may lack pull-requests (its mint asks for
  # contents alone, cmux-next-base-autofix.yml). Unset: the push token.
  pr_token="${PR_TOKEN:-$token}"
  unset PR_TOKEN
  # Global, and removed on EXIT: set -e ends the script without returning from main.
  work="$(mktemp -d)"
  trap 'rm -rf "${work:-}"' EXIT
  root="$(git rev-parse --show-toplevel)"
  # The run's own push and area rules, copied before a checkout of the tip can change them. The repair
  # and the defaults guard on the tip are the tip's own (in the checkout).
  cp "$here/autofix-areas.sh" "$work/autofix-areas.sh"
  areas_script="${CMUX_BASE_AUTOFIX_AREAS:-$work/autofix-areas.sh}"
  push_script="${CMUX_BASE_AUTOFIX_PUSH:-}"
  if [[ -z "$push_script" ]]; then
    cp "$here/base-autofix-push.sh" "$work/push.sh"
    cp "$here/settings-exports.txt" "$work/settings-exports.txt"
    push_script="$work/push.sh"
    export CMUX_BASE_AUTOFIX_AREAS="$areas_script"
  fi
  # The compile gate for Swift changes (base-autofix-compile-gate.sh), copied with the push. The workflow turns
  # it on by passing COMPILE_GATE_TOKEN; like TOKEN, only the push sees the token, never the repair.
  # CMUX_BASE_AUTOFIX_COMPILE_GATE names another gate (tests).
  gate_token="${COMPILE_GATE_TOKEN:-}"
  unset COMPILE_GATE_TOKEN
  compile_gate="${CMUX_BASE_AUTOFIX_COMPILE_GATE:-}"
  unset CMUX_BASE_AUTOFIX_COMPILE_GATE
  if [[ -z "$compile_gate" && -n "$gate_token" ]]; then
    cp "$here/base-autofix-compile-gate.sh" "$work/compile-gate.sh"
    compile_gate="$work/compile-gate.sh"
  fi
  : > "$work/compiled"
  repair_script="${CMUX_BASE_AUTOFIX_REPAIR:-$root/scripts/cmux-next/base-autofix-repair.sh}"

  # A held file a round on the tip makes again (base-autofix-push.sh's output areas graph, sdk,
  # ratchets, cloud and fmt; what is built from the exports when they are current on the tip). The
  # rest needs the Mac job or an artifact made at an older commit.
  remade() {
    case "$1" in
      Packages/macOS/CmuxNext/ci-target-graph.json | plans/cmux-next/daemon-capabilities.json | cmux-tui/bindings/* | scripts/lint-namespace-types-ratchet.txt \
        | clients/ts/cloud/* | cmux-tui/crates/cmux-cloud-wire/src/generated/*) return 0 ;;
      # The docs reference pages (base-autofix.sh step 1e1) follow the exports, as the docs shortcuts do.
      web/data/next-docs/settings-reference.generated.json) ((actions_current && settings_current)) ;;
      web/data/next-docs/*.generated.json) ((actions_current)) ;;
      # The namespace lint's safe rewrites (base-autofix.sh 1f', with --ratchets).
      Packages/*.swift | ios/cmux/*.swift) return 0 ;;
      web/data/cmux-shortcuts.generated.json | cmux-tui/crates/cmux-app-host/generated/* \
        | Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform/*) ((actions_current)) ;;
      schemas/defaults/cmux-next.json) ((actions_current && settings_current)) ;;
      # The Chief inspector page comes from the webviews patch.
      Native/OptChat/optchat-chief/inspector/*) return 1 ;;
      cmux-tui/* | Native/OptChat/*) return 0 ;;
      *) return 1 ;;
    esac
  }

  # The tip's action exports are this run's or a newer commit's own: this run made them
  # (ACTIONS_MADE_AT; the CI target graph job makes none and has no bun), and none was held.
  exports_landed() { # <held so far>
    [[ -n "$actions_made_at" ]] || return 1
    ! grep -qE "$action_exports" <<<"$1"
  }

  # Swift the repair rewrote (the namespace lint's rewrites, base-autofix.sh 1f') is code the app
  # compiles, and this job has no compile check. 8f33d7030473 pushed such a rewrite (an enum another
  # file imported with `import enum` became a struct) straight onto feat-cmux-next, and the Release
  # compile was red on every push after it (run 44005736927). So a rewritten Swift file never lands
  # on BRANCH from here: it goes, as made, to SOURCES_BRANCH on the commit the repair was made at,
  # with a pull request whose CI compiles it, and the rest of the repair lands as before.
  # Package.swift is not a rewrite (the FFI pin writes it through its own path).
  sources_branch="${CMUX_BASE_AUTOFIX_SOURCES_BRANCH:-base-autofix-sources}"
  with_token() { # <command...>: the push credentials for this one command only
    if [[ -n "$token" ]]; then
      local auth
      auth="$(printf 'x-access-token:%s' "$token" | base64 -w0)"
      env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
        GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" GH_TOKEN="$token" "$@"
    else
      "$@"
    fi
  }
  with_pr_token() { # <gh command...>: the pull-request token for this one command only
    if [[ -n "$pr_token" ]]; then GH_TOKEN="$pr_token" "$@"; else "$@"; fi
  }
  propose_sources() { # <base> <paths>: the rewrite as a commit on <base>, pushed to SOURCES_BRANCH, with its pull request
    local on="$1" paths="$2" path entry tree commit previous number path_list
    local idx="$work/sources-index"
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git read-tree "$on"
    while IFS= read -r path; do
      entry="$(git ls-tree HEAD -- "$path")"
      if [[ -n "$entry" ]]; then
        GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "$(awk '{print $1 "," $3}' <<<"${entry%%$'\t'*}"),$path"
      else
        GIT_INDEX_FILE="$idx" git update-index --force-remove -- "$path"
      fi
    done <<<"$paths"
    tree="$(GIT_INDEX_FILE="$idx" git write-tree)"
    commit="$(git commit-tree "$tree" -p "$on" -m "chore(next): base autofix at ${on:0:12} (Swift rewrites, for a pull request)" \
      -m "$(sed 's/^/- namespace rewrite in /' <<<"$paths")" \
      -m "scripts/cmux-next/base-autofix-land.sh: ${RUN_URL:-} could not compile these, so they wait for this pull request's CI instead of landing on $branch.")"
    # The same rewrite again (every base push makes it while it waits) leaves the branch, and its CI, alone.
    if ! previous="$(remote_refs . "$remote" "refs/heads/$sources_branch")"; then
      echo "::warning title=Base autofix Swift rewrites::$remote did not answer; they are left out of $branch and the next run makes them again" >&2
      return 0
    fi
    previous="$(cut -f1 <<<"$previous")"
    if [[ -n "$previous" ]] && git fetch --quiet --no-tags "$remote" "$previous" 2>/dev/null \
      && [[ "$(git diff --name-only "$previous^" "$previous" 2>/dev/null)" == "$(sort <<<"$paths")" ]] \
      && mapfile -t path_list <<<"$paths" && git diff --quiet "$previous" "$commit" -- "${path_list[@]}"; then
      echo "The Swift rewrites already wait on $sources_branch (${previous:0:12}) for their pull request's compile."
      return 0
    fi
    if ! with_token git push --quiet --force "$remote" "$commit:refs/heads/$sources_branch"; then
      echo "::warning title=Base autofix Swift rewrites::could not push them to $sources_branch; they are left out of $branch and the next run makes them again" >&2
      return 0
    fi
    echo "Left the Swift rewrites out of $branch: they wait on $sources_branch (${commit:0:12}) for a pull request whose CI compiles them."
    if [[ -z "${GITHUB_REPOSITORY:-}" ]] || ! command -v gh >/dev/null; then
      echo "::warning title=Base autofix Swift rewrites::open the pull request for $sources_branch into $branch by hand"
      return 0
    fi
    number="$(with_pr_token gh pr list --repo "$GITHUB_REPOSITORY" --base "$branch" --head "$sources_branch" --state open \
      --json number --jq '.[0].number // empty' 2>/dev/null || true)"
    [[ -z "$number" ]] || { echo "Its pull request #$number compiles the new head."; return 0; }
    if ! with_pr_token gh pr create --repo "$GITHUB_REPOSITORY" --base "$branch" --head "$sources_branch" \
      --title "chore(next): base autofix Swift rewrites" \
      --body "The base autofix rewrote these Swift files (the namespace lint's safe rewrites) and could not compile them, so they wait here for this pull request's CI instead of landing on $branch (8f33d7030473 broke the Release compile that way). Made by ${RUN_URL:-the base autofix}; a newer run replaces the head.

$(sed 's/^/- /' <<<"$paths")

## Changelog

none" >/dev/null; then
      echo "::warning title=Base autofix Swift rewrites::could not open the pull request for $sources_branch into $branch; open it by hand"
    fi
    return 0
  }
  split_sources() { # <base>: moves the Swift HEAD rewrote out of HEAD; 1 when nothing is left to push
    local on="$1" paths path message
    paths="$(git diff --name-only "$on" HEAD -- '*.swift' | grep -Ev '(^|/)Package\.swift$' || true)"
    [[ -n "$paths" ]] || return 0
    propose_sources "$on" "$paths"
    message="$(git log -1 --format=%B HEAD | grep -vF -f <(printf '%s\n' "$paths") || true)"
    while IFS= read -r path; do
      if git cat-file -e "$on:$path" 2>/dev/null; then
        git checkout --quiet "$on" -- "$path"
      else
        git rm --quiet --cached -- "$path" && rm -f -- "$path"
      fi
    done <<<"$paths"
    if git diff --cached --quiet "$on"; then
      git reset --quiet --hard "$on"
      return 1
    fi
    git commit --quiet --amend --file=- <<<"$message"  # keeps the repair's own subject
  }

  push() { # <base> [<settings made at>] [<action exports made at>] -> the push's status; its held files in $work/held
    local auth status=0
    : > "$work/held"
    split_sources "$1" || return 0
    if [[ -n "$token" ]]; then
      auth="$(printf 'x-access-token:%s' "$token" | base64 -w0)"
      env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
        GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" CMUX_BASE_AUTOFIX_HELD="$work/held" \
        CMUX_BASE_AUTOFIX_COMPILE_GATE="$compile_gate" COMPILE_GATE_TOKEN="$gate_token" CMUX_BASE_AUTOFIX_COMPILED="$work/compiled" \
        "$push_script" "$remote" "$branch" "$@" || status=$?
    else
      CMUX_BASE_AUTOFIX_HELD="$work/held" \
        CMUX_BASE_AUTOFIX_COMPILE_GATE="$compile_gate" COMPILE_GATE_TOKEN="$gate_token" CMUX_BASE_AUTOFIX_COMPILED="$work/compiled" \
        "$push_script" "$remote" "$branch" "$@" || status=$?
    fi
    return "$status"
  }

  waits=""  # held files no round here makes: the run fails for them
  round=1
  status=0
  push "$base" "$settings_made_at" "$actions_made_at" || status=$?
  while ((status != 0)); do
    held="$(grep . "$work/held" || true)"
    if [[ -z "$held" ]]; then
      exit "$status"  # not a hold: a rejected push, a conflict, an unreadable history
    fi
    git fetch --quiet --no-tags "$remote" "refs/heads/$branch" || {
      echo "::error::cannot read $branch from the remote to make the repair again" >&2
      exit 1
    }
    tip="$(git rev-parse FETCH_HEAD)"
    git checkout --quiet --force --detach "$tip"
    git clean --quiet -fd
    # ghostty-next, when this job initialized it for cargo clippy --fix, follows the tip's gitlink, so
    # the remade clippy repair builds against that tip's libghostty-vt. A failed update leaves the
    # remade clippy repair to report "left:"; it never stops the other repairs.
    if [[ -e ghostty-next/.git ]]; then
      bash scripts/ci/init-submodule.sh ghostty-next >/dev/null 2>&1 \
        || echo "::warning::could not move ghostty-next to ${tip:0:12}'s gitlink" >&2
    fi
    actions_current=0 settings_current=0
    if exports_landed "$held"$'\n'"$waits"; then
      actions_current=1
      judged="$base"
      if [[ -n "$settings_made_at" ]]; then
        judged="$settings_made_at"
        grep -qE "$settings_exports" <<<"$held"$'\n'"$waits" && judged=""
      fi
      # Exports this run made and none held: the tip holds them, as made at SETTINGS_MADE_AT, or as
      # progress past a move of their inputs (base-autofix-push.sh), and what is built from them is made
      # from the exports committed beside it, as for the action exports. Without them the tip's own
      # guard (it finds the repository from its own path) derives both stamps.
      if [[ -n "$settings_made_at" && -n "$judged" ]]; then
        settings_current=1
      elif [[ -n "$judged" && -f "$root/scripts/ci/defaults_guard.py" ]] \
        && judged_stamp="$(python3 "$root/scripts/ci/defaults_guard.py" source-stamp --ref "$judged" 2>/dev/null)" \
        && [[ -n "$judged_stamp" ]] \
        && [[ "$judged_stamp" == "$(python3 "$root/scripts/ci/defaults_guard.py" source-stamp --ref "$tip" 2>/dev/null)" ]]; then
        settings_current=1
      fi
    fi
    again=""
    while IFS= read -r path; do
      if remade "$path"; then again+="$path"$'\n'; else waits+="$path"$'\n'; fi
    done <<<"$held"
    if [[ -z "$again" ]]; then
      exit "$status"
    fi
    if ((round >= rounds)); then
      echo "::error::$branch kept moving the inputs of these through $rounds rounds; the next run repairs them:" >&2
      printf '%s' "$again" | sed 's/^/  /' >&2
      exit 1
    fi
    round=$((round + 1))
    echo "Making the repair again on ${tip:0:12} (round $round of $rounds): $branch moved the inputs of $(printf '%s' "$again" | tr '\n' ' ')"
    CMUX_BASE_AUTOFIX_AGAIN=1 CMUX_BASE_AUTOFIX_ACTION_EXPORTS_CURRENT="$actions_current" \
      CMUX_BASE_AUTOFIX_SETTINGS_EXPORTS_CURRENT="$settings_current" "$repair_script" "$root" | tee "$work/repair.txt" || {
      echo "::error::making the repair again on ${tip:0:12} failed" >&2
      exit 1
    }
    # A submodule the job initialized (ghostty-next, for cargo clippy --fix) stays at the commit it
    # was checked out at, so a tip that moved its gitlink shows it modified: a repair never writes a
    # gitlink, and staging it would undo that move on the branch.
    git add -A
    while IFS= read -r -d '' gitlink; do
      git reset --quiet -- "$gitlink"
    done < <(git diff --cached --raw -z --no-renames | python3 -I -c '
import sys
parts = sys.stdin.buffer.read().split(b"\0")
for meta, path in zip(parts[0::2], parts[1::2]):
    modes = meta.split()[:2]
    if b"160000" in (m.lstrip(b":") for m in modes):
        sys.stdout.buffer.write(path + b"\0")
')
    if git diff --cached --quiet; then
      echo "$branch at ${tip:0:12} needs none of it again."
      status=0
      break
    fi
    git commit --quiet -m "chore(next): base autofix at ${tip:0:12}" \
      -m "$(grep '^fixed: ' "$work/repair.txt" | sed 's/^fixed: /- /')" \
      -m "Made again on ${tip:0:12}: it moved the inputs of a repair made at ${base:0:12}." \
      -m "scripts/cmux-next/base-autofix.sh: ${RUN_URL:-}"
    status=0
    push "$tip" || status=$?
  done
  if [[ -n "$waits" ]]; then
    echo "::error::these wait for the next run (their Mac export, or what they are built from, moved):" >&2
    printf '%s' "$waits" | sort -u | sed 's/^/  /' >&2
    exit 1
  fi
  exit 0
}
main "$@"; exit $?
