#!/usr/bin/env bash
# A NEXT nightly that starts before its own cmux-tui tree is published
# (NIGHTLY_NEXT_TREE_AT_INSTALL in nightly.yml) compiles the app first and then
# waits here, after xcodebuild, for the client it will install. Prints the
# commit whose commit-addressed manifest (https://files.cmux.com/cmux-tui/<commit>/manifest.json)
# to install, the same manifest the nightly would have installed had it waited
# for the tree before starting:
#   1. once tree <key> is published and verified, the commit its source.json
#      names (pin-cmux-tui.sh verify-key: the tree's sha256 is the one that
#      commit's manifest carries). That is exactly today's resolve.
#   2. before that, the first of <candidate>... (the build commit and its
#      first-parent ancestors with the same tree key, oldest first: the one
#      that changed the key is the one whose artifacts run builds it) whose
#      manifest exists. A manifest is uploaded last, after every binary, so it
#      exists only for a complete upload. The install that follows
#      (install-cmux-tui-client.sh --expected-commit) checks its build-provenance
#      attestation and every sha256; nothing here is trusted beyond "it exists".
# publish-nightly runs only once the build commit's tree-commit marker names
# the printed commit as the tree's publisher (await-nightly-tree-marker), so a
# client from a commit that did not publish the tree is never published.
#
# Fails fast when nothing will publish the tree: every CMUX_TUI_TREE_CLIENT_RUN_CHECK_SECONDS
# (default 300) it reads each candidate's cmux-tui artifacts runs (pin-cmux-tui.sh runs-state)
# and then pin-cmux-tui.sh active-publisher <key>, and two answers
# in a row of "no active cmux-tui artifacts run has this tree" end the wait
# (an unreadable runs list keeps waiting). An active run counts only while it makes
# progress (pin-cmux-tui.sh run-progress): a build failed on its last retry attempt, or a job queued with no runner
# past CMUX_TUI_TREE_RUNNER_STALL_SECONDS (default 900), is "not building" too. Otherwise it waits up to
# CMUX_TUI_TREE_CLIENT_WAIT_SECONDS (default 2700), checking every
# CMUX_TUI_TREE_CLIENT_POLL_SECONDS (default 20). CMUX_TUI_TREE_CLIENT_WAIT_SECONDS=0
# looks once (the tree, then each candidate's manifest) and exits 1 on a miss
# without reading any runs list. app-bundle-cmux-tui-client.sh, when it has a fallback tree,
# waits CMUX_TUI_TREE_CLIENT_FALLBACK_WAIT_SECONDS (default 1500) here, then bundles the
# newest published tree on a miss instead of failing (RFD 0021, row 1).
# A publisher rebuilding its failed primary macOS leg (pin-cmux-tui.sh run-progress: rebuilding)
# extends the limit by up to CMUX_TUI_TREE_CLIENT_REBUILD_GRACE_SECONDS (default 1200) while it
# keeps reading so. That rebuild lands the tree about 30 min after a clean run would: 2026-11-27,
# NIGHTLY 46057516701 (03fefcf7) stopped at its 1500 s limit, 6 min before artifacts run
# 46057516735 uploaded the tip's manifest, and bundled the cmux and acpmux CLI of 2bfbcf5a.
#
# Usage: await-tree-client.sh <tree key> <candidate commit>...
# Env: CMUX_TUI_PIN_BASE (default https://files.cmux.com/cmux-tui), GH_TOKEN
# (actions: read, for the runs list). Exit 0 with the commit on stdout, 1 when
# nothing is published in time or nothing will publish it, 2 on bad usage.
set -euo pipefail

key="${1:-}"
shift || true
[[ "$key" =~ ^[0-9a-f]{40}$ ]] || { echo "error: the first argument must be a 40-hex tree key" >&2; exit 2; }
(( $# > 0 )) || { echo "error: name at least one candidate commit" >&2; exit 2; }
for candidate in "$@"; do
  [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || { echo "error: candidate $candidate is not a 40-hex commit" >&2; exit 2; }
done
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"
wait_seconds="${CMUX_TUI_TREE_CLIENT_WAIT_SECONDS:-2700}"
poll_seconds="${CMUX_TUI_TREE_CLIENT_POLL_SECONDS:-20}"
check_seconds="${CMUX_TUI_TREE_CLIENT_RUN_CHECK_SECONDS:-300}"
rebuild_grace="${CMUX_TUI_TREE_CLIENT_REBUILD_GRACE_SECONDS:-1200}"
[[ "$wait_seconds" =~ ^[0-9]+$ ]] || { echo "error: CMUX_TUI_TREE_CLIENT_WAIT_SECONDS must be whole seconds" >&2; exit 2; }
[[ "$rebuild_grace" =~ ^[0-9]+$ ]] || { echo "error: CMUX_TUI_TREE_CLIENT_REBUILD_GRACE_SECONDS must be whole seconds" >&2; exit 2; }
rebuild_grace=$((10#$rebuild_grace))
for value in "$poll_seconds" "$check_seconds"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "error: the CMUX_TUI_TREE_CLIENT_*_SECONDS values must be positive whole seconds" >&2; exit 2; }
done
wait_seconds=$((10#$wait_seconds))

# 0 when <commit>'s manifest answers 200 (a complete transfer), 1 otherwise.
manifest_exists() {
  local code
  code="$(curl -sS --proto '=https' --connect-timeout 20 --max-time 60 -o /dev/null -w '%{http_code}' \
    "$base/$1/manifest.json?t=$(date +%s)" 2>/dev/null)" || return 1
  [[ "$code" == 200 ]]
}

started=$(date +%s)
next_check=0
idle_checks=0
rebuilding=false
while :; do
  rc=0
  out="$(bash "$script_dir/pin-cmux-tui.sh" verify-key "$key" 2>/dev/null)" || rc=$?
  if (( rc == 0 )); then
    commit="$(sed -n 's/^commit=//p' <<<"$out" | head -1)"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: verify-key printed no commit for tree $key" >&2; exit 1; }
    echo "tree $key is published by ${commit:0:12}; installing its client" >&2
    echo "$commit"
    exit 0
  fi
  for candidate in "$@"; do
    if manifest_exists "$candidate"; then
      echo "the manifest of ${candidate:0:12} (tree $key) is uploaded after $(( $(date +%s) - started )) s; installing its client before the tree publishes" >&2
      echo "$candidate"
      exit 0
    fi
  done
  if (( wait_seconds == 0 )); then
    echo "tree $key is not published and no candidate manifest is uploaded (looked once)" >&2
    exit 1
  fi
  elapsed=$(( $(date +%s) - started ))
  if (( elapsed >= next_check )); then
    next_check=$(( elapsed + check_seconds ))
    # The candidates' own runs first (a filtered read each), then the newest runs of any
    # commit with this tree: 50 newer runs elsewhere must not hide a candidate's publisher.
    # An active run counts only while its jobs make progress (pin-cmux-tui.sh run-progress):
    # one whose build failed on its last retry attempt, or whose job has sat queued with no runner past
    # CMUX_TUI_TREE_RUNNER_STALL_SECONDS (default 900), is passed over for another same-key
    # run, and when none is left the wait ends at the second check instead of the 45 min
    # limit (2026-11-18: owner 44240874997's Linux build failed and the takeover run's Linux
    # builds sat queued on Blacksmith while nightly 44243166776 waited blind).
    # pin-cmux-tui.sh tree-publisher is the reading resolve-tree-pending.sh also uses.
    publisher="" stuck="" rebuilding=false
    # Its notes (a rate limit, a failed read) go to a file: an unknown answer prints the last one,
    # so the log says why the runs could not be read (nightly 46095639816 printed only "waiting on").
    publisher_notes="$(mktemp "${TMPDIR:-/tmp}/await-tree-notes.XXXXXX")"
    found="$(bash "$script_dir/pin-cmux-tui.sh" tree-publisher "$key" "$@" 2>"$publisher_notes" || echo unknown)"
    publisher_why="$(grep -v '^$' "$publisher_notes" | tail -1 || true)"
    rm -f "$publisher_notes"
    case "$found" in
      building\ *) publisher="${found#building }" ;;
      rebuilding\ *) publisher="${found#rebuilding }" rebuilding=true ;;
      stuck\ *) stuck="${found#stuck }" ;;
      ended|none) ;;
      *) publisher=unknown ;;
    esac
    case "$publisher" in
      unknown) idle_checks=0; echo "the cmux-tui artifacts runs could not all be read (${publisher_why:-no note}); waiting on" >&2 ;;
      "")
        idle_checks=$(( idle_checks + 1 ))
        if [[ -n "$stuck" ]]; then
          echo "no cmux-tui artifacts run with tree $key is making progress: $stuck (check $idle_checks of 2)" >&2
        else
          echo "no active cmux-tui artifacts run has tree $key (check $idle_checks of 2)" >&2
        fi ;;
      *)
        idle_checks=0
        if [[ "$rebuilding" == true ]]; then
          echo "the cmux-tui artifacts run of ${publisher:0:12} is building tree $key (rebuilding its failed primary macOS leg)" >&2
        else
          echo "the cmux-tui artifacts run of ${publisher:0:12} is building tree $key" >&2
        fi ;;
    esac
    if (( idle_checks >= 2 )); then
      if [[ -n "$stuck" ]]; then
        echo "error: tree $key is not published, no candidate manifest is uploaded, and no cmux-tui artifacts run that builds it is making progress ($stuck); nothing will publish it in time" >&2
      else
        echo "error: tree $key is not published, no candidate manifest is uploaded, and no active cmux-tui artifacts run builds it; nothing will publish it" >&2
      fi
      exit 1
    fi
  fi
  if (( elapsed >= wait_seconds )) && [[ "$rebuilding" == true ]] && (( elapsed < wait_seconds + rebuild_grace )); then
    if [[ -z "${grace_noted:-}" ]]; then
      grace_noted=1
      echo "the limit of $(( wait_seconds / 60 )) min passed while ${publisher:0:12} rebuilds its macOS leg; waiting up to $(( rebuild_grace / 60 )) min more" >&2
    fi
  elif (( elapsed >= wait_seconds )); then
    echo "error: tree $key is not published and no candidate manifest is uploaded after $(( elapsed / 60 )) min" >&2
    exit 1
  fi
  sleep "$poll_seconds"
done
