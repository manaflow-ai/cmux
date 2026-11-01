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
# older published revision and failed cargo build --locked.
set -euo pipefail
# Prints commit=, key=, source_commit=, tip_key=, behind= and
# behind_hours= lines and writes them to the step summary.
resolved="$(scripts/cmux-next/pin-cmux-tui.sh resolve-newest-published)"
printf '%s\n' "$resolved"
grep -Eq '^commit=[0-9a-f]{40}$' <<<"$resolved"
grep -Eq '^source_commit=[0-9a-f]{40}$' <<<"$resolved"
grep -Eq '^key=[0-9a-f]{40}$' <<<"$resolved"
printf '%s\n' "$resolved" >> "$GITHUB_OUTPUT"
