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
# both exports, also needs the settings exports' inputs on the tip to be the ones this run judged
# them at: the tip's sources give the same source stamp (defaults_guard.py source-stamp, derived from
# each tree; the stamp is never committed) as SETTINGS_MADE_AT when this run made them and none was
# held, or else as BASE_SHA, whose committed exports the first push built the snapshot from. Otherwise,
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
  action_exports='^plans/cmux-next/(action-surfaces\.json|actions\.md|links\.json)$'
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
  rounds="${CMUX_BASE_AUTOFIX_ROUNDS:-3}"
  token="${TOKEN:-}"
  unset TOKEN
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
  repair_script="${CMUX_BASE_AUTOFIX_REPAIR:-$root/scripts/cmux-next/base-autofix-repair.sh}"

  # A held file a round on the tip makes again (base-autofix-push.sh's output areas graph, sdk,
  # ratchets, cloud and fmt; what is built from the exports when they are current on the tip). The
  # rest needs the Mac job or an artifact made at an older commit.
  remade() {
    case "$1" in
      Packages/macOS/CmuxNext/ci-target-graph.json | plans/cmux-next/daemon-capabilities.json | cmux-tui/bindings/* | scripts/lint-namespace-types-ratchet.txt \
        | clients/ts/cloud/* | cmux-tui/crates/cmux-cloud-wire/src/generated/*) return 0 ;;
      # The namespace lint's safe rewrites (base-autofix.sh 1f', with --ratchets).
      Packages/*.swift | ios/cmux/*.swift) return 0 ;;
      web/data/cmux-shortcuts.generated.json | cmux-tui/crates/cmux-app-host/generated/*) ((actions_current)) ;;
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

  push() { # <base> [<settings made at>] [<action exports made at>] -> the push's status; its held files in $work/held
    local auth status=0
    : > "$work/held"
    if [[ -n "$token" ]]; then
      auth="$(printf 'x-access-token:%s' "$token" | base64 -w0)"
      env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
        GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" CMUX_BASE_AUTOFIX_HELD="$work/held" \
        "$push_script" "$remote" "$branch" "$@" || status=$?
    else
      CMUX_BASE_AUTOFIX_HELD="$work/held" "$push_script" "$remote" "$branch" "$@" || status=$?
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
    actions_current=0 settings_current=0
    if exports_landed "$held"$'\n'"$waits"; then
      actions_current=1
      judged="$base"
      if [[ -n "$settings_made_at" ]]; then
        judged="$settings_made_at"
        grep -qE "$settings_exports" <<<"$held"$'\n'"$waits" && judged=""
      fi
      # The tip's own guard (it finds the repository from its own path) derives both stamps.
      if [[ -n "$judged" && -f "$root/scripts/ci/defaults_guard.py" ]] \
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
    if [[ -z "$(git status --porcelain)" ]]; then
      echo "$branch at ${tip:0:12} needs none of it again."
      status=0
      break
    fi
    git add -A
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
