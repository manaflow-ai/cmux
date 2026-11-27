#!/usr/bin/env bash
# The machine channel's plan for a pull request head (PR_HEAD_FAST_LANE, cmux-machine-channel.yml): build the
# head's thin Linux pair only when it is this repository's, into feat-cmux-next, and its merge with the base (HEAD,
# a two-commit checkout) changes the v2 tree key; a pull request never points. Writes build, the
# machine_channel profile (scripts/cmux-next/cmux-tui-build-profiles.json) and nothing else to $GITHUB_OUTPUT.
#
# pr-router.yml's route job runs this in its own checkout (git trees only: ls-tree, one inputs blob), so a pull
# request head starts no runner for "does the machine channel need this commit": that job was a whole runner and a
# fetch-depth 200 checkout for a 0.3 s answer, 1,460 runner-min in 6 h (943 runs, 2026-11-26 02Z..08Z). The plan
# job runs it too when the router passed no answer (the route step failed), so the answer never depends on it.
#
# cmux_tui_tree_key.py takes `[--version V] [REV]`: the `key` subcommand every caller named before (#56753) is no
# argument it reads, so each key came back empty and every full-tier head built both targets.
#
# Env: HEAD_REPO (the head's owner/name), GITHUB_REPOSITORY, GITHUB_BASE_REF, GITHUB_OUTPUT; optional HEAD_SHA, HEAD_REF and
# GH_TOKEN (actions: read) for the earlier-build lookup, GITHUB_RUN_ID to leave this run out of it.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

python3 -I -c '
import json, sys
p = json.load(open(sys.argv[1]))["machine_channel"]
for k in ("x86_64_target_set", "aarch64_target_set", "lto", "artifact_prefix"):
    print(f"{k}={p[k]}")' "$root/scripts/cmux-next/cmux-tui-build-profiles.json" >> "$GITHUB_OUTPUT"

build=false
mine="" base="" head=""
if [[ "${GITHUB_REPOSITORY:-}" == manaflow-ai/cmux && "${HEAD_REPO:-}" == "${GITHUB_REPOSITORY:-}" \
      && "${GITHUB_BASE_REF:-}" == feat-cmux-next ]]; then
  tk="$here/cmux_tui_tree_key.py"
  mine="$("$here/timeout.sh" 60 python3 "$tk" --version v2 HEAD 2>/dev/null)" || mine=""
  base="$("$here/timeout.sh" 60 python3 "$tk" --version v2 HEAD^1 2>/dev/null)" || base=""
  # An unread key builds (fail open) but says so: a CLI misuse read as "keys differ" built every head for a day.
  if [[ -z "$mine" || -z "$base" ]]; then
    echo "::warning title=machine channel PR head build::no v2 tree key (merge ${mine:-none}, base ${base:-none}): building"
  fi
  if [[ -z "$mine" || -z "$base" || "$mine" != "$base" ]]; then build=true; fi
  # A head behind the base (its own key is not its merge's) squashes to another tree, so
  # cmux_machine_channel_pr_head.py find never takes its build: skip it (#58380). The land queue's
  # update-branch makes a new, up-to-date head, which builds.
  if [[ "$build" == true && -n "$mine" ]]; then
    head="$("$here/timeout.sh" 60 python3 "$tk" --version v2 HEAD^2 2>/dev/null)" || head=""
    if [[ -n "$head" && "$head" != "$mine" ]]; then
      echo "::notice title=machine channel PR head build::head key $head != merge key $mine: the head is behind the base, no merge can take this build"
      build=false
    fi
  fi
  # A base that took a commit in the last QUIET minutes has a push run of cmux-machine-channel.yml for it, waiting
  # on its head's build or building. That group runs one and keeps one waiting, and every newer push replaces the
  # waiting one, so this head's merge, minutes later, is coalesced into whichever push runs next and its build is
  # never taken. 2026-11-25 21Z..11-26 21Z: 1,290 merges, a median 36 s apart, none 20 min after the one before;
  # 27 push runs; about 1,700 PR head builds a target (a build cost about 50k job-min, 48 min a merged PR) for at
  # most 27 takes. A base quiet that long (a slow hour) still builds, and the push run builds whenever no PR build
  # has its tree, as before. MACHINE_CHANNEL_PR_HEAD_QUIET_MIN (vars.CI_MACHINE_CHANNEL_PR_HEAD_QUIET_MIN) 0 turns
  # it off. Before the earlier-build lookup, so a skip costs no API call.
  quiet="${MACHINE_CHANNEL_PR_HEAD_QUIET_MIN:-30}"
  if [[ "$build" == true && "$quiet" =~ ^[0-9]+$ && "$quiet" -gt 0 ]]; then
    based="$(git log -1 --format=%ct HEAD^1 2>/dev/null)" || based=""
    if [[ "$based" =~ ^[0-9]+$ ]]; then
      age=$(( ($(date +%s) - based) / 60 ))
      if (( age < quiet )); then
        echo "::notice title=machine channel PR head build::the base took a commit ${age} min ago (< ${quiet}): its push run coalesces this merge, no PR head build"
        build=false
      fi
    fi
  fi
  # The same head handed to land again (ready-to-land, then full-ci, a label pulsed, a re-queue) builds the same
  # bytes: the build checks out the head SHA, and the merge's finder takes any of its runs with both artifacts.
  # Skip it when an earlier pr-router run of this head has them (cmux_machine_channel_head_built.py). A base merge
  # makes a new head SHA with the same tree key when the base moved no input: an earlier head of the branch with
  # key $mine built the same inputs, so it counts too (--key, --branch; the merge's finder takes it the same way).
  if [[ "$build" == true && "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ && -n "${GH_TOKEN:-}" ]]; then
    prefix="$(sed -n 's/^artifact_prefix=//p' "$GITHUB_OUTPUT" | tail -n1)"
    prior="$("$here/timeout.sh" 90 python3 -I "$here/cmux_machine_channel_head_built.py" "$HEAD_SHA" \
      --exclude-run "${GITHUB_RUN_ID:-0}" --prefix "${prefix:-machine-channel-}" \
      --key "$mine" --branch "${HEAD_REF:-}" 2>/dev/null)" || prior=""
    if [[ "$prior" =~ ^[0-9]+$ ]]; then
      echo "::notice title=machine channel PR head build::run $prior already built head $HEAD_SHA or a head with its tree key $mine: no second build"
      build=false
    fi
  fi
fi
echo "::notice title=machine channel PR head build::build=$build (merge key ${mine:-none}, base key ${base:-none}, head key ${head:-none})"
echo "build=$build" >> "$GITHUB_OUTPUT"
