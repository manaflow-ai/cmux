#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Resolve cmux-tui client commit". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Never ship a stale build: more than 24 h behind the tip fails.
# This run executes the tip's nightly.yml against the resolved
# commit, so the resolved commit must carry the same file: run
# 37568319518 called a dSYM script its older build commit lacked.
# Preserve Chief lockfile repairs too: run 37724899486 selected an
# older published revision and failed cargo build --locked. The step
# scripts the workflow calls from that checkout must be the tip's (#30912).
set -euo pipefail
# nightly-next (TRACK): a tip whose own tree is not published builds the TIP's app with the newest published
# tree whose daemon-capabilities.json matches (scripts/cmux-next/older-tree-for-tip.sh; Leo, 2026-11-26: "cant
# we just accept the nightly using an older tui version"). Then source_commit= is the tip, commit= and key= name
# the older tree, and tree_from= "<its commit> <commits> <hours>" says how far behind it is. request-nightly-next.sh
# promotes on the same answer. Anything else (the tip's tree published, none matching, a read failure) resolves
# as before: the newest published tree, the build at its commit.
if [[ "${TRACK:-}" == nightly-next ]]; then
  older_rc=0
  older="$(bash scripts/cmux-next/older-tree-for-tip.sh)" || older_rc=$?
  if (( older_rc == 0 )); then
    printf '%s\n' "$older"
    printf '%s\n' "$older" >> "$GITHUB_OUTPUT"
    read -r from from_behind from_hours <<<"$(sed -n 's/^tree_from=//p' <<<"$older")"
    key="$(sed -n 's/^key=//p' <<<"$older")"
    echo "::warning title=cmux-tui tree::the tip's own cmux-tui tree is not published; its app bundles tree $key of ${from:0:12} ($from_behind commits, $from_hours h older, same daemon-capabilities.json)"
    {
      echo "### cmux-tui client"
      echo "- tree: \`$key\` from the older commit \`$from\` ($from_behind commits and $from_hours h behind the tip); the tip's own tree \`$(sed -n 's/^tip_key=//p' <<<"$older")\` is not published"
      echo "- build commit (app): the tip \`$(git rev-parse HEAD)\`; daemon-capabilities.json matches"
      echo "- publishing commit (manifest sha256 verified): \`$(sed -n 's/^commit=//p' <<<"$older")\`"
    } >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
fi
# Prints commit=, key=, source_commit=, tip_key=, behind= and
# behind_hours= lines and writes them to the step summary.
resolved="$(scripts/cmux-next/pin-cmux-tui.sh resolve-newest-published)"
printf '%s\n' "$resolved"
grep -Eq '^commit=[0-9a-f]{40}$' <<<"$resolved"
grep -Eq '^source_commit=[0-9a-f]{40}$' <<<"$resolved"
grep -Eq '^key=[0-9a-f]{40}$' <<<"$resolved"
printf '%s\n' "$resolved" >> "$GITHUB_OUTPUT"
