#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Upload dSYMs to Sentry". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# A missing or broken uploader never blocks a publish either: run 37568319518 ran this
# workflow over an older build_sha checkout without the script.
# Retried, and only a warning when Sentry stays down: a nightly is never lost to symbolication.
# The fast build also uploads the Rust client's dSYMs (cmux-tui, cmux-tui-host, cmux-holder; acpmux is
# linked into cmux-tui), when the build step above made them.
# It runs in the background while the unsigned app and the kept dSYMs upload (it held
# this serialized warm slot 38-39 s after them in runs 39509829525, 39519824930); "Finish
# the dSYM upload to Sentry" waits for it. The FIFO write blocks until that step reads
# it, so the status is never lost and nothing polls.
set -uo pipefail
paths=(build-universal/Build/Products/Release/)
for dsym in cmux-tui/target/aarch64-apple-darwin/release/cmux-tui.dSYM \
            cmux-tui/target/aarch64-apple-darwin/release/cmux-tui-host.dSYM \
            cmux-tui/target/aarch64-apple-darwin/release/cmux-holder.dSYM; do
  [ -d "$dsym" ] && paths+=("$dsym")
done
state="$RUNNER_TEMP/sentry-dsyms"
rm -rf "$state"
mkdir -p "$state"
mkfifo "$state/status.fifo"
(
  status=0
  ./scripts/upload-sentry-dsyms.sh "${paths[@]}" || status=$?
  echo "$status" >"$state/status.fifo"
) >"$state/upload.log" 2>&1 </dev/null &
echo "dSYM upload to Sentry started (PID $!)"
