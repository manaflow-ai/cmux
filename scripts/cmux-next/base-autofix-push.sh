#!/usr/bin/env bash
# Pushes base autofix's repair commit (HEAD, one commit on top of BASE_SHA) to
# BRANCH of REMOTE, and lands what is still right on the newest tip.
# feat-cmux-next takes a push every minute or two and the Mac export takes ten
# or more, so a run usually finds the branch moved.
#
# A file never lands as it was made at BASE_SHA when the tip moved its inputs:
# the areas of the paths changed in BASE_SHA..tip (autofix-areas.sh, the same
# input paths that decide the repairs) hold every output those areas build,
# so a revert in between can't land a wrong export. A file is also held when a
# commit since BASE_SHA wrote it itself (a pull request's own regeneration, or
# a base autofix repair made from a newer tree), when it adds into a directory
# a newer commit removed, and when no area is known to build it. An earlier
# base autofix repair made from an older tree is replaced. The exports land as
# a whole or not at all (the settings schema and docs/mdm; the
# four action exports), and files built from an export that waits wait with
# it. The defaults snapshot reads flags anywhere in the app's sources, so it is
# never copied: on a moved tip it is derived again there
# (scripts/ci/defaults_guard.py snapshot), and only when nothing else waits.
#
# The settings exports are judged from SETTINGS_MADE_AT, the commit the Mac
# job made them at (base-autofix-settings-exports.sh regenerates them on the
# newest tip while their inputs move; without it, BASE_SHA), and land whole, as
# made there (every file of the list below whose made copy differs from the
# tip's). A SETTINGS_MADE_AT that is not between BASE_SHA and the tip holds them.
# A move of the settings area whose sources give the same source stamp at the
# tip as at SETTINGS_MADE_AT (defaults_guard.py source-stamp, derived from each
# tree; the stamp is never committed), with the regeneration as it was, changed
# none of their inputs. When SETTINGS_MADE_AT..tip did move their inputs they
# still land, as progress, the way the action exports do (only with SETTINGS_MADE_AT given;
# without it a move holds them): the tip's committed
# copy is older still, and the next push run makes them on the newer tip.
# Holding them instead meant none landed while settings merges outran the Mac
# job, and feat-cmux-next kept the settings.agents.cmuxMcp.ask row #51725 had
# removed, red in every web bundle build (2026-11-23, run 45126925631). When a
# commit after SETTINGS_MADE_AT wrote one of them itself, they wait and the run
# fails: whether the tip's own copies are current takes the Mac export to say.
#
# The action exports are judged from ACTIONS_MADE_AT, the commit the Mac job made them at
# (base-autofix-action-exports.sh; without it, BASE_SHA), and land whole, as made there. When
# ACTIONS_MADE_AT..tip moved the actions area they still land, as progress: the next push run makes
# them on the newer tip. Holding them instead meant none landed while merges outran the regeneration
# (run 39633520123, 2026-10-21). When a commit after ACTIONS_MADE_AT wrote one of them itself, its
# copy stays (a generated file takes either side) and this repair drops them; nothing waits for them.
# Their inputs are the actions area only; the shortcuts and app-host areas hold what is built from
# them, which base-autofix-land.sh makes again on the tip from the exports there.
#
# The rest lands; when anything waited the run still fails, so the next run
# diffs from an older successful one and repairs it. Nothing already on the tip
# is pushed again (no empty commit). Each push is a plain push, retried on a
# moved tip up to CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS times (5).
#
# Usage: scripts/cmux-next/base-autofix-push.sh REMOTE BRANCH BASE_SHA [SETTINGS_MADE_AT] [ACTIONS_MADE_AT]
# Credentials come from the caller's environment (GIT_CONFIG_* extraheader).
# CMUX_BASE_AUTOFIX_AREAS names the area script (default: autofix-areas.sh beside this one).
# CMUX_BASE_AUTOFIX_HELD names a file for the list of held files.
set -euo pipefail
remote="${1:?usage: $0 REMOTE BRANCH BASE_SHA}"
branch="${2:?usage: $0 REMOTE BRANCH BASE_SHA}"
base="${3:?usage: $0 REMOTE BRANCH BASE_SHA [SETTINGS_MADE_AT]}"
settings_made_at="${4:-}"
actions_made_at="${5:-}"
attempts="${CMUX_BASE_AUTOFIX_PUSH_ATTEMPTS:-5}"
# The subject of base autofix's own commits (cmux-next-base-autofix.yml); the
# SHA after "at" is the tree the repair was made from. Only the subject counts.
autofix_subject='^chore\(next\): base autofix at ([0-9a-f]{7,40})([^0-9a-f]|$)'
snapshot=schemas/defaults/cmux-next.json
# Every file of the settings export: scripts/cmux-next/settings-exports.txt is the one list, which
# regenerate-settings-exports.sh exports and check-settings-exports.sh restores.
settings_exports=()
while IFS= read -r cmux_next_export; do settings_exports+=("$cmux_next_export"); done < <(
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$(dirname "${BASH_SOURCE[0]}")/settings-exports.txt")
(( ${#settings_exports[@]} )) || { echo "::error::scripts/cmux-next/settings-exports.txt lists no export" >&2; exit 1; }
# Every file of the action export (regenerate-action-exports.sh writes the same list).
action_exports=(plans/cmux-next/action-surfaces.json plans/cmux-next/action-catalog.json plans/cmux-next/actions.md plans/cmux-next/links.json)
areas_script="${CMUX_BASE_AUTOFIX_AREAS:-$(dirname "${BASH_SOURCE[0]}")/autofix-areas.sh}"

# The areas whose inputs a list of changed paths (stdin) touches.
input_areas() {
  local lines
  lines="$("$areas_script")" || return 1
  sed -n 's/=true$//p' <<<"$lines" | sort -u
}
# The areas that build each output (stdin; base-autofix.sh's outputs). A file built from several
# areas names them all; one this list doesn't know is "unknown", which never lands on a moved tip.
output_areas() {
  local path
  while IFS= read -r path; do
    case "$path" in
      Packages/macOS/CmuxNext/ci-target-graph.json) echo graph ;;
      */generated/strings.json) echo strings; echo webviews ;;
      cmux-tui/bindings/*) echo sdk ;;
      # The exports read the actions area only; what is built from them follows them (built_from).
      plans/cmux-next/action-surfaces.json | plans/cmux-next/action-catalog.json | plans/cmux-next/actions.md | plans/cmux-next/links.json) echo actions ;;
      plans/cmux-next/daemon-capabilities.json) echo capabilities ;;
      schemas/settings/settings-schema.json | docs/mdm/*) echo settings ;;
      "$snapshot") echo settings; echo actions ;;
      web/data/cmux-shortcuts.generated.json) echo shortcuts; echo actions ;;
      # The docs reference pages (base-autofix.sh 1e1): the settings reference from the settings export,
      # the others from the action export. Unclaimed, they never landed on a moved tip while the schema
      # did, and the docs test stayed red on feat-cmux-next (dee3e635, #39914). All of them are also
      # built by web/scripts/export-next-docs.ts, which the shortcuts area holds: a new generator on the
      # tip holds what the old one wrote.
      web/data/next-docs/settings-reference.generated.json) echo settings; echo shortcuts ;;
      web/data/next-docs/*.generated.json) echo actions; echo shortcuts ;;
      cmux-tui/crates/cmux-app-host/generated/* | Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform/*) echo apphost; echo actions ;;
      scripts/lint-namespace-types-ratchet.txt) echo ratchets ;;
      # The undeclared-job record (base-autofix.sh 6).
      scripts/ci/job-inputs-always.json) echo jobinputs ;;
      # The namespace lint's safe rewrites (base-autofix.sh 1f').
      Packages/*.swift | ios/cmux/*.swift) echo ratchets ;;
      clients/ts/cloud/* | cmux-tui/crates/cmux-cloud-wire/src/generated/*) echo cloud ;;
      webviews/*) echo webviews ;;
      # The Cargo locks (base-autofix.sh --locks) follow every Cargo manifest (autofix-areas.sh locks); before
      # cmux-tui/*, which would claim cmux-app-ffi's lock for formatting.
      Cargo.lock | */Cargo.lock) echo locks ;;
      # The iPhone app's uniffi Swift bindings (base-autofix.sh 5a).
      cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/*) echo iosffi ;;
      # Undeclared jobs recorded as runs-always (base-autofix.sh 6, job_inputs.py fix).
      scripts/ci/job-inputs-always.json) echo jobinputs ;;
      cmux-tui/* | Native/OptChat/*) echo fmt ;;
      *) echo unknown ;;
    esac
  done | sort -u
}

# The export a file is part of; an export lands whole (regenerate-*-exports.sh list them).
export_of() {
  case "$1" in
    plans/cmux-next/action-surfaces.json | plans/cmux-next/action-catalog.json | plans/cmux-next/actions.md | plans/cmux-next/links.json) echo actions ;;
    schemas/settings/settings-schema.json | docs/mdm/*) echo settings ;;
  esac
}
# The exports a file is generated from (base-autofix.sh). The snapshot is derived again instead.
built_from() {
  case "$1" in
    web/data/cmux-shortcuts.generated.json | cmux-tui/crates/cmux-app-host/generated/* \
      | Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform/*) echo actions ;;
    */generated/strings.json | web/data/next-docs/settings-reference.generated.json) echo settings ;;
    web/data/next-docs/*.generated.json) echo actions ;;
  esac
}

repair="$(git rev-parse HEAD)"
base="$(git rev-parse "$base^{commit}")"
[[ "$(git rev-parse HEAD^)" == "$base" ]] || {
  echo "::error::the repair commit is not one commit on top of ${base:0:12}" >&2
  exit 1
}
repaired="$(git diff --name-only --no-renames "$base" "$repair" | sort -u)"

# The files commits in FROM..TIP wrote that this repair must not overwrite: every commit but
# a base autofix repair, and a base autofix repair made from a tree after FROM. A commit is
# base autofix's by its subject only (a body can quote one: a squash merge).
# Fails when history can't be read, so an unreadable range never reads as "nothing newer".
newer_writes() { # <from> <tip>
  local from="$1" tip="$2" log line subject made include=1
  log="$(git log --first-parent --diff-merges=first-parent --no-renames --name-only \
    --format='%x01%s' "$from..$tip")" || return 1
  while IFS= read -r line; do
    if [[ "$line" == $'\x01'* ]]; then
      subject="${line#$'\x01'}"
      include=1
      if [[ "$subject" =~ $autofix_subject ]]; then
        made="$(git rev-parse -q --verify "${BASH_REMATCH[1]}^{commit}" 2>/dev/null || true)"
        include=0
        if [[ -n "$made" && "$made" != "$from" ]] && git merge-base --is-ancestor "$from" "$made" 2>/dev/null; then
          include=1
        fi
      fi
    elif [[ -n "$line" ]] && ((include)); then
      printf '%s\n' "$line"
    fi
  done <<<"$log"
}
is_settings_export() { [[ "$(export_of "$1")" == settings ]]; }
is_action_export() { [[ "$(export_of "$1")" == actions ]]; }
# The commit an export was made at: MADE_AT when it is a commit between BASE_SHA and TIP; else it
# prints nothing and fails (the caller holds the export).
made_from() { # <made-at> <tip>
  local from=""
  [[ "$1" =~ ^[0-9a-f]{40}$ ]] && from="$(git rev-parse -q --verify "$1^{commit}" 2>/dev/null || true)"
  [[ -n "$from" ]] && git merge-base --is-ancestor "$base" "$from" 2>/dev/null \
    && git merge-base --is-ancestor "$from" "$2" 2>/dev/null && echo "$from"
}
# The settings exports' inputs are what their source stamp hashes (CmuxNextSettings and the two
# export tests; defaults_guard.py source-stamp derives it for a commit). Exports made where the
# sources give the tip's stamp, by the same regeneration, are exactly what the tip would make,
# however else the settings area moved (a note beside the sources, the guard, the bot's own
# scripts). Fails closed: any read that fails counts as moved.
settings_inputs_same() { # <made-at> <tip>
  local made stamp
  made="$(python3 scripts/ci/defaults_guard.py source-stamp --ref "$1" 2>/dev/null)" || return 1
  stamp="$(python3 scripts/ci/defaults_guard.py source-stamp --ref "$2" 2>/dev/null)" || return 1
  [[ -n "$made" && "$made" == "$stamp" ]] || return 1
  git diff --quiet "$1" "$2" -- scripts/cmux-next/regenerate-settings-exports.sh 2>/dev/null
}

held=""
# CMUX_BASE_AUTOFIX_HELD names a file that gets the held files, one per line,
# when the run ends on a hold (base-autofix-land.sh makes the ones it can again on the tip).
# Only a hold writes it (held_exit): a run that pushed nothing for another reason (the branch kept
# moving, a rejection, an unreadable tip) leaves it empty, so no stale list reads as a hold.
held_exit=0
# The names of the tests a swift_parity log reports FAILED, sorted, one per line.
parity_failed_tests() { sed -n 's/^test \([^ ]*\) \.\.\. FAILED$/\1/p' "$1" | LC_ALL=C sort -u; }
trap 'if [[ -n "${CMUX_BASE_AUTOFIX_HELD:-}" ]]; then if ((held_exit)); then printf "%s" "$held"; fi > "$CMUX_BASE_AUTOFIX_HELD"; fi' EXIT
# The action catalog's swift_parity test in checkout DIR. land.sh injects its write token through
# git's config environment. Cargo executes build scripts/tests: none may inherit publication
# credentials. The parent retains its authentication for fetch/push; only this check runs without it.
action_parity() { # <dir>
  (
    unset TOKEN GH_TOKEN GITHUB_TOKEN COMPILE_GATE_TOKEN GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
    for auth_var in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
      [[ -z "$auth_var" ]] || unset "$auth_var"
    done
    cd "$1"
    cargo test --locked --manifest-path "$1/cmux-tui/Cargo.toml" -p cmux-action-catalog --test swift_parity
  )
}
# The same check at commit REV, in a throwaway worktree that builds into this checkout's target dir.
action_parity_at() { # <rev>
  local dir status=0
  dir="$(mktemp -d)"
  git worktree add --quiet --detach "$dir/tree" "$1" || { rm -rf "$dir"; return 0; }
  CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(git rev-parse --show-toplevel)/cmux-tui/target}" action_parity "$dir/tree" || status=$?
  git worktree remove --force "$dir/tree" >/dev/null 2>&1 || true
  rm -rf "$dir"
  return "$status"
}
# The tip the last rejected push went onto; a rejection that did not move the branch is no race.
rejected_on=""
# The compile gate's verdicts in this push ("pass|fail PATCH_ID" lines), and the Swift files it held this attempt.
compile_verdicts=""
for ((attempt = 1; attempt <= attempts; attempt++)); do
  git fetch --quiet --no-tags "$remote" "refs/heads/$branch" || {
    echo "::error::cannot read $branch from the remote" >&2
    exit 1
  }
  tip="$(git rev-parse FETCH_HEAD)"
  if [[ "$tip" == "$rejected_on" ]]; then
    echo "::error::the push was rejected but $branch did not move from ${tip:0:12}; see the push output above." >&2
    exit 1
  fi
  held=""
  compile_held=""
  # Where the settings exports were made: BASE_SHA, or a commit between it and the tip.
  settings_from="$base"
  settings_unproven=""
  if [[ -n "$settings_made_at" ]]; then
    settings_from=""
    if [[ "$settings_made_at" =~ ^[0-9a-f]{40}$ ]]; then
      settings_from="$(git rev-parse -q --verify "$settings_made_at^{commit}" 2>/dev/null || true)"
    fi
    if [[ -z "$settings_from" ]] \
      || ! git merge-base --is-ancestor "$base" "$settings_from" 2>/dev/null \
      || ! git merge-base --is-ancestor "$settings_from" "$tip" 2>/dev/null; then
      settings_unproven="the settings exports were made at ${settings_made_at:0:12}, which is not a commit between ${base:0:12} and ${tip:0:12}"
      settings_from="$base"
    fi
  fi
  # Where the action exports were made, the same way.
  actions_from="$base"
  actions_unproven=""
  if [[ -n "$actions_made_at" ]]; then
    actions_from="$(made_from "$actions_made_at" "$tip")" || {
      actions_unproven="the action exports were made at ${actions_made_at:0:12}, which is not a commit between ${base:0:12} and ${tip:0:12}"
      actions_from="$base"
    }
  fi
  if [[ "$tip" == "$base" && "$settings_from" == "$base" && -z "$settings_unproven" \
    && "$actions_from" == "$base" && -z "$actions_unproven" ]]; then
    git checkout --quiet --detach "$repair"
  else
    newer="$(newer_writes "$base" "$tip")" || {
      echo "::error::cannot read the commits ${base:0:12}..${tip:0:12} wrote, so nothing lands over them" >&2
      exit 1
    }
    newer="$(grep . <<<"$newer" | sort -u || true)"
    newer_settings="$newer"
    moved_areas="$(git diff --name-only --no-renames "$base" "$tip" | input_areas)" || {
      echo "::error::cannot read what ${base:0:12}..${tip:0:12} changed, so nothing lands over it" >&2
      exit 1
    }
    todo="$repaired"
    if [[ "$settings_from" != "$base" ]]; then
      # The settings exports are judged from where they were made, and land whole as made there.
      newer_settings="$(newer_writes "$settings_from" "$tip")" || {
        echo "::error::cannot read the commits ${settings_from:0:12}..${tip:0:12} wrote, so nothing lands over them" >&2
        exit 1
      }
      newer_settings="$(grep . <<<"$newer_settings" | sort -u || true)"
      # Each step fails closed on its own: a failed diff or area read never reads as "nothing moved".
      settings_changed="$(git diff --name-only --no-renames "$settings_from" "$tip")" || {
        echo "::error::cannot read what ${settings_from:0:12}..${tip:0:12} changed, so the settings exports made at ${settings_from:0:12} do not land" >&2
        exit 1
      }
      settings_areas="$(input_areas <<<"$settings_changed")" || {
        echo "::error::cannot read the input areas ${settings_from:0:12}..${tip:0:12} changed, so the settings exports made at ${settings_from:0:12} do not land" >&2
        exit 1
      }
      moved_areas="$(grep -vx settings <<<"$moved_areas" || true)"
      if grep -qx settings <<<"$settings_areas"; then moved_areas+=$'\n'settings; fi
      moved_areas="$(grep . <<<"$moved_areas" | sort -u || true)"
      todo="$( { printf '%s\n' "$repaired"; git diff --name-only --no-renames "$settings_from" "$repair" -- "${settings_exports[@]}"; } | grep . | sort -u)"
    fi
    newer_actions="$newer"
    if [[ "$actions_from" != "$base" ]]; then
      # The action exports are judged from where they were made, and land whole as made there.
      newer_actions="$(newer_writes "$actions_from" "$tip")" || {
        echo "::error::cannot read the commits ${actions_from:0:12}..${tip:0:12} wrote, so nothing lands over them" >&2
        exit 1
      }
      newer_actions="$(grep . <<<"$newer_actions" | sort -u || true)"
      actions_changed="$(git diff --name-only --no-renames "$actions_from" "$tip")" || {
        echo "::error::cannot read what ${actions_from:0:12}..${tip:0:12} changed, so the action exports made at ${actions_from:0:12} do not land" >&2
        exit 1
      }
      actions_areas="$(input_areas <<<"$actions_changed")" || {
        echo "::error::cannot read the input areas ${actions_from:0:12}..${tip:0:12} changed, so the action exports made at ${actions_from:0:12} do not land" >&2
        exit 1
      }
      moved_areas="$(grep -vx actions <<<"$moved_areas" || true)"
      if grep -qx actions <<<"$actions_areas"; then moved_areas+=$'\n'actions; fi
      moved_areas="$(grep . <<<"$moved_areas" | sort -u || true)"
      todo="$( { printf '%s\n' "$todo"; git diff --name-only --no-renames "$actions_from" "$repair" -- "${action_exports[@]}"; } | grep . | sort -u)"
    fi
    if [[ -n "$actions_unproven" ]]; then
      echo "::error::$actions_unproven; they wait." >&2
      moved_areas="$(printf '%s\nactions\n' "$moved_areas" | grep . | sort -u)"
    fi
    [[ -z "$settings_unproven" ]] || moved_areas="$(printf '%s\nsettings\n' "$moved_areas" | grep . | sort -u)"
    if [[ -z "$settings_unproven" ]] && grep -qx settings <<<"$moved_areas" \
      && grep -q . <(while IFS= read -r path; do is_settings_export "$path" && echo "$path"; done <<<"$todo") \
      && settings_inputs_same "$settings_from" "$tip"; then
      echo "The settings exports' inputs are unchanged on ${tip:0:12} (its sources give the source stamp of ${settings_from:0:12}); they are not held for the settings area's move."
      moved_areas="$(grep -vx settings <<<"$moved_areas" || true)"
    fi
    # A bad SETTINGS_MADE_AT is a workflow defect: the exports wait and the run fails with an error.
    if [[ -n "$settings_unproven" ]]; then
      echo "::error::$settings_unproven; they wait." >&2
    fi
    # The settings exports whose inputs moved after SETTINGS_MADE_AT land as progress, unless a newer
    # commit wrote one of them itself (then the held_set loop below holds them, and the run fails).
    # A revert after SETTINGS_MADE_AT of a change that carried its export writes the export, so it
    # holds them; one whose change carried none left the tip's copy as stale as this one. Without
    # SETTINGS_MADE_AT (no Mac export named where it was made) a move still holds them (#22474).
    partial_settings=0
    todo_settings="$(while IFS= read -r path; do [[ -z "$path" ]] || ! is_settings_export "$path" || echo "$path"; done <<<"$todo" | sort -u)"
    if [[ -n "$settings_made_at" && -z "$settings_unproven" && -n "$todo_settings" ]] && grep -qx settings <<<"$moved_areas" \
      && [[ -z "$(comm -12 <(printf '%s\n' "$todo_settings") <(printf '%s\n' "$newer_settings"))" ]]; then
      partial_settings=1
      echo "::warning::$branch moved the settings exports' inputs after ${settings_from:0:12}; the exports made there land as progress, and the next run makes them on the newer tip."
    fi
    # The action exports this repair holds: a newer commit's own copy stays, else they land as progress.
    partial_actions=0
    todo_actions="$(while IFS= read -r path; do [[ -z "$path" ]] || ! is_action_export "$path" || echo "$path"; done <<<"$todo" | sort -u)"
    if [[ -z "$actions_unproven" && -n "$todo_actions" ]]; then
      if [[ -n "$(comm -12 <(printf '%s\n' "$todo_actions") <(printf '%s\n' "$newer_actions"))" ]]; then
        echo "A commit after ${actions_from:0:12} wrote the action exports itself; its copy stays, and this repair's is dropped."
        todo="$(while IFS= read -r path; do [[ -z "$path" ]] || is_action_export "$path" || echo "$path"; done <<<"$todo")"
      elif grep -qx actions <<<"$moved_areas"; then
        partial_actions=1
        echo "::warning::$branch moved the action exports' inputs after ${actions_from:0:12}; the exports made there land as progress, and the next run makes them on the newer tip."
      fi
    fi
    held_set=""
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      # The snapshot is derived again on the tip (below); only moved inputs and other waits hold it.
      if ! { ((partial_actions)) && is_action_export "$path"; } \
        && ! { ((partial_settings)) && is_settings_export "$path"; } \
        && { grep -qxF unknown <<<"$(output_areas <<<"$path")" \
          || [[ -n "$(comm -12 <(output_areas <<<"$path") <(printf '%s\n' "$moved_areas"))" ]]; }; then
        held_set+="$path"$'\n'
        continue
      fi
      [[ "$path" != "$snapshot" ]] || continue
      if is_settings_export "$path"; then
        writes="$newer_settings"
      elif is_action_export "$path"; then
        writes="$newer_actions"
      else
        writes="$newer"
      fi
      if grep -qxF -- "$path" <<<"$writes"; then
        held_set+="$path"$'\n'
        continue
      fi
      # A file the repair adds into a directory a newer commit removed.
      git cat-file -e "$base:$path" 2>/dev/null && continue
      dir="$(dirname "$path")"
      [[ "$dir" == . ]] && continue
      if git cat-file -e "$base:$dir" 2>/dev/null && ! git cat-file -e "$tip:$dir" 2>/dev/null; then
        held_set+="$path"$'\n'
      fi
    done <<<"$todo"
    # An export lands whole, and what is built from a held export waits with it.
    waiting="$(while IFS= read -r path; do
      if [[ -n "$path" ]]; then export_of "$path"; fi
    done <<<"$held_set" | sort -u)"
    kept=()
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      group="$(export_of "$path")"
      if grep -qxF -- "$path" <<<"$held_set" \
        || { [[ -n "$group" ]] && grep -qxF -- "$group" <<<"$waiting"; } \
        || [[ -n "$(comm -12 <(built_from "$path" | sort -u) <(printf '%s\n' "$waiting"))" ]]; then
        held+="$path"$'\n'
      else
        kept+=("$path")
      fi
    done <<<"$todo"
    # The snapshot never lands beside a file that waits: it reads them all.
    if [[ -n "$held" ]] && grep -qxF -- "$snapshot" <<<"$todo" && ! grep -qxF -- "$snapshot" <<<"$held"; then
      held+="$snapshot"$'\n'
      still=()
      for path in "${kept[@]}"; do
        [[ "$path" == "$snapshot" ]] || still+=("$path")
      done
      kept=(${still[@]+"${still[@]}"})
    fi
    if ((${#kept[@]} == 0)) && [[ -z "$held" ]]; then
      echo "$branch at ${tip:0:12} already holds what is left of this repair; nothing to push."
      exit 0
    fi
    if ((${#kept[@]} == 0)); then
      held_exit=1
      echo "::error::$branch moved to ${tip:0:12} after ${base:0:12} and changed the inputs or the files of everything this repair writes; the newer run repairs them:" >&2
      printf '%s' "$held" | sed 's/^/  /' >&2
      exit 1
    fi
    echo "$branch moved to ${tip:0:12} after ${base:0:12} (attempt $attempt of $attempts); writing ${#kept[@]} repaired file(s) onto it."
    git checkout --quiet --detach "$tip"
    for path in "${kept[@]}"; do
      if [[ "$path" == "$snapshot" ]]; then
        continue
      elif git cat-file -e "$repair:$path" 2>/dev/null; then
        git checkout --quiet "$repair" -- "$path"
      else
        git rm --quiet --cached --ignore-unmatch -- "$path"
        rm -f -- "$path"
      fi
    done
    if printf '%s\n' "${kept[@]}" | grep -qxF -- "$snapshot"; then
      if [[ -f scripts/ci/defaults_guard.py ]] && python3 scripts/ci/defaults_guard.py snapshot >/dev/null; then
        git add -- "$snapshot"
      else
        echo "::warning::could not derive $snapshot on ${tip:0:12}; it waits for the next run" >&2
        git checkout --quiet "$tip" -- "$snapshot" 2>/dev/null || true
        held+="$snapshot"$'\n'
      fi
    fi
    if git diff --cached --quiet; then
      if [[ -n "$held" ]]; then
        held_exit=1
        echo "::error::$branch ${tip:0:12} already holds the repairs that could land; left to the next run:" >&2
        printf '%s' "$held" | sed 's/^/  /' >&2
        exit 1
      fi
      echo "$branch at ${tip:0:12} already holds this repair; nothing to push."
      exit 0
    fi
    message="$(git log -1 --format=%B "$repair")"
    message+=$'\n\n'"Re-applied on ${tip:0:12}, which $branch moved to after ${base:0:12}."
    [[ -z "$held" ]] || message+=$'\n'"Left to the next run (newer commits changed them or their inputs): $(printf '%s' "$held" | tr '\n' ' ')"
    git commit --quiet -m "$message"
  fi
  # The compile gate (CMUX_BASE_AUTOFIX_COMPILE_GATE, base-autofix-compile-gate.sh): a candidate whose
  # repair changes a Swift file lands that Swift only after the build fleet compiles the candidate.
  # 8f33d7030 pushed a namespace rewrite that did not compile, and every base compile stayed red. A
  # verdict is kept per compiled tree: the candidate's Packages/ and ios/ trees (every Swift source,
  # Package.swift and pin the compile reads), here and in CMUX_BASE_AUTOFIX_COMPILED across
  # base-autofix-land.sh's rounds. A retry onto a tip that moved only outside them reuses the verdict;
  # one that moved a Swift source or a package compiles again (review F1 of #45139).
  # Without a pass the Swift files are put back to the tip's, the rest lands, and the run fails.
  if [[ -n "${CMUX_BASE_AUTOFIX_COMPILE_GATE:-}" ]]; then
    swift_changed="$(git diff --name-only "$tip" HEAD -- '*.swift')"
    if [[ -n "$swift_changed" ]]; then
      compiled_tree="$(printf '%s %s\n' "$(git rev-parse -q --verify HEAD:Packages || echo none)" "$(git rev-parse -q --verify HEAD:ios || echo none)" | git hash-object --stdin)"
      verdict="$(grep -h " $compiled_tree\$" ${CMUX_BASE_AUTOFIX_COMPILED:+"$CMUX_BASE_AUTOFIX_COMPILED"} <(printf '%s' "${compile_verdicts:-}") 2>/dev/null | tail -n 1 | cut -d' ' -f1)" || verdict=""
      if [[ -z "$verdict" ]]; then
        gate=0
        "$CMUX_BASE_AUTOFIX_COMPILE_GATE" "$remote" "$(git rev-parse HEAD)" || gate=$?
        verdict=fail
        ((gate == 0)) && verdict=pass
        compile_verdicts+="$verdict $compiled_tree"$'\n'
        [[ -z "${CMUX_BASE_AUTOFIX_COMPILED:-}" ]] || echo "$verdict $compiled_tree" >> "$CMUX_BASE_AUTOFIX_COMPILED"
      else
        echo "Compile gate: this Swift change already has a verdict in this run ($verdict)."
      fi
      if [[ "$verdict" != pass ]]; then
        while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          if git cat-file -e "$tip:$path" 2>/dev/null; then
            git checkout --quiet "$tip" -- "$path"
          else
            git rm --quiet --cached --ignore-unmatch -- "$path"
            rm -f -- "$path"
          fi
        done <<<"$swift_changed"
        compile_held="$swift_changed"
        if git diff --quiet "$tip" -- && git diff --cached --quiet "$tip" --; then
          echo "::error::the build fleet did not pass this repair's Swift changes at ${tip:0:12}, and nothing else is left to push; not pushed:" >&2
          printf '%s\n' "$swift_changed" | sed 's/^/  /' >&2
          echo "next: fix the generator that wrote them (base-autofix.sh), or the base if it does not compile on its own." >&2
          [[ -z "$held" ]] || held_exit=1
          exit 1
        fi
        git add -A -- $(printf '%s\n' "$swift_changed")
        git commit --quiet --amend --no-edit
      fi
    fi
  fi
  # Judge the final candidate, including a repair reconstructed on a moved tip. A source,
  # export or re-pin marker disagreement is never safe progress. Keep this inside the retry
  # loop: a green result for the old candidate does not cover the next one.
  # A candidate that fails only tests the tip already fails is no worse than the tip and lands.
  parity_log="$(mktemp)"
  if ! action_parity "$(git rev-parse --show-toplevel)" 2>&1 | tee "$parity_log"; then
    candidate_failed="$(parity_failed_tests "$parity_log")"
    tip_failed=""
    if [[ -n "$candidate_failed" ]]; then
      tip_tree="$(mktemp -d)"
      if git worktree add --quiet --detach "$tip_tree/tree" "$tip" >/dev/null 2>&1; then
        echo "swift_parity failed on the candidate ($(echo $candidate_failed)); checking the tip ${tip:0:12}."
        CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(git rev-parse --show-toplevel)/cmux-tui/target}" \
          action_parity "$tip_tree/tree" > "$parity_log.tip" 2>&1 || true
        tip_failed="$(parity_failed_tests "$parity_log.tip")"
        git worktree remove --force "$tip_tree/tree" >/dev/null 2>&1 || true
      fi
      rm -rf "$tip_tree" "$parity_log.tip"
    fi
    if [[ -n "$candidate_failed" ]]; then
      new_failed="$(LC_ALL=C comm -23 <(printf '%s\n' "$candidate_failed") <(printf '%s\n' "$tip_failed") | sed '/^$/d')"
      if [[ -n "$new_failed" ]]; then
        echo "::error::swift_parity failed at $(git rev-parse HEAD); no automatic repair was pushed." >&2
        echo "failing here but passing at the tip ${tip:0:12}: $(echo $new_failed)" >&2
        echo "next: regenerate all action exports at this head and reconcile the re-pin markers in a reviewed fix, then rerun base autofix." >&2
        rm -f "$parity_log"
        exit 1
      fi
      echo "::warning::swift_parity fails at the tip ${tip:0:12} too ($(echo $tip_failed)); this repair adds no failure, so it lands. The tip's own red needs the action exports regenerated."
    else
      # Older parity runners can fail before naming tests. Preserve the existing safety rule:
      # an unnamed failure is accepted only when the tip has the same red and this repair did
      # not modify any input consumed by swift_parity.
      parity_reads="$(sed -n 's#^ *// affected-reads: ##p' \
        "$(git rev-parse --show-toplevel)/cmux-tui/crates/cmux-action-catalog/tests/swift_parity.rs" 2>/dev/null | head -1 || true)"
      parity_reads="${parity_reads:-plans/cmux-next/action-catalog.json plans/cmux-next/action-surfaces.json Packages/macOS/CmuxNext/Sources cmux-tui/crates/cmux-action-catalog}"
      # shellcheck disable=SC2086 # parity_reads is a list of paths
      if git diff --quiet "$tip" HEAD -- $parity_reads cmux-tui/Cargo.lock cmux-tui/Cargo.toml \
        && ! action_parity_at "$tip"; then
        echo "::warning::swift_parity fails at the base tip ${tip:0:12} too, and this repair writes none of its inputs; pushing the repair anyway. The base red is its own fix."
      else
        echo "::error::swift_parity failed at $(git rev-parse HEAD); no automatic repair was pushed." >&2
        echo "next: regenerate all action exports at this head and reconcile the re-pin markers in a reviewed fix, then rerun base autofix." >&2
        rm -f "$parity_log"
        exit 1
      fi
    fi
  fi
  rm -f "$parity_log"
  # A plain push: it fails rather than overwrite a commit pushed meanwhile.
  if git push --quiet "$remote" "HEAD:refs/heads/$branch"; then
    echo "Pushed $(git rev-parse --short HEAD) to $branch."
    if [[ -n "${compile_held:-}" ]]; then
      echo "::error::pushed the repair without its Swift changes, which the build fleet did not pass; not pushed:" >&2
      printf '%s\n' "$compile_held" | sed 's/^/  /' >&2
      echo "next: fix the generator that wrote them (base-autofix.sh), or the base if it does not compile on its own." >&2
      [[ -z "$held" ]] || held_exit=1
      exit 1
    fi
    if [[ -n "$held" ]]; then
      held_exit=1
      echo "::error::pushed part of the repair; newer commits changed these or their inputs, so the next run repairs them:" >&2
      printf '%s' "$held" | sed 's/^/  /' >&2
      exit 1
    fi
    exit 0
  fi
  rejected_on="$tip"
  echo "The push to $branch was refused (attempt $attempt of $attempts); reading the tip again."
done
# Exit 75 (EX_TEMPFAIL): the branch kept moving. base-autofix-land.sh passes the run on it, since the
# run each of those pushes started repairs it; any other exit is a real refusal.
echo "::warning title=Base autofix::$branch kept moving; the next run repairs it." >&2
exit 75
