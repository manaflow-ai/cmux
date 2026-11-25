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
# (an unreadable runs list keeps waiting). Otherwise it waits up to
# CMUX_TUI_TREE_CLIENT_WAIT_SECONDS (default 2700), checking every
# CMUX_TUI_TREE_CLIENT_POLL_SECONDS (default 20).
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
for value in "$wait_seconds" "$poll_seconds" "$check_seconds"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "error: the CMUX_TUI_TREE_CLIENT_*_SECONDS values must be positive whole seconds" >&2; exit 2; }
done

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
  elapsed=$(( $(date +%s) - started ))
  if (( elapsed >= next_check )); then
    next_check=$(( elapsed + check_seconds ))
    # The candidates' own runs first (a filtered read each), then the newest runs of any
    # commit with this tree: 50 newer runs elsewhere must not hide a candidate's publisher.
    publisher=""
    for candidate in "$@"; do
      case "$(bash "$script_dir/pin-cmux-tui.sh" runs-state "$candidate" 2>/dev/null || echo unknown)" in
        active) publisher="$candidate"; break ;;
        unknown) publisher=unknown ;;
      esac
    done
    if [[ -z "$publisher" ]]; then
      publisher="$(bash "$script_dir/pin-cmux-tui.sh" active-publisher "$key" 2>/dev/null || echo unknown)"
    fi
    case "$publisher" in
      unknown) idle_checks=0; echo "the cmux-tui artifacts runs could not all be read; waiting on" >&2 ;;
      "") idle_checks=$(( idle_checks + 1 )); echo "no active cmux-tui artifacts run has tree $key (check $idle_checks of 2)" >&2 ;;
      *) idle_checks=0; echo "the cmux-tui artifacts run of ${publisher:0:12} is building tree $key" >&2 ;;
    esac
    if (( idle_checks >= 2 )); then
      echo "error: tree $key is not published, no candidate manifest is uploaded, and no active cmux-tui artifacts run builds it; nothing will publish it" >&2
      exit 1
    fi
  fi
  if (( elapsed >= wait_seconds )); then
    echo "error: tree $key is not published and no candidate manifest is uploaded after $(( elapsed / 60 )) min" >&2
    exit 1
  fi
  sleep "$poll_seconds"
done
