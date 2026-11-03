#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Download signing inputs (parallel)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# download-artifact reads each blob over one connection. Fetch all three
# signing inputs over ranged HTTP concurrently, while retaining the
# action downloads as per-artifact fallbacks if a ranged request fails.
set +e
mkdir -p nightly-inputs/app nightly-inputs/ghostty remote-daemon-assets
python3 scripts/ci/download-run-artifact.py \
  --name cmux-nightly-unsigned-app --out nightly-inputs/app \
  --connections 64 \
  >"$RUNNER_TEMP/nightly-app-download.log" 2>&1 &
app_pid=$!
python3 scripts/ci/download-run-artifact.py \
  --name cmux-nightly-remote-daemon --out remote-daemon-assets \
  >"$RUNNER_TEMP/nightly-daemon-download.log" 2>&1 &
daemon_pid=$!
python3 scripts/ci/download-run-artifact.py \
  --name cmux-nightly-ghostty-cli-helper --out nightly-inputs/ghostty \
  >"$RUNNER_TEMP/nightly-helper-download.log" 2>&1 &
helper_pid=$!
wait "$app_pid"; app_status=$?
wait "$daemon_pid"; daemon_status=$?
wait "$helper_pid"; helper_status=$?
for log in \
  "$RUNNER_TEMP/nightly-app-download.log" \
  "$RUNNER_TEMP/nightly-daemon-download.log" \
  "$RUNNER_TEMP/nightly-helper-download.log"; do
  cat "$log"
done
app_ok=false; daemon_ok=false; helper_ok=false
[ "$app_status" -eq 0 ] && app_ok=true
[ "$daemon_status" -eq 0 ] && daemon_ok=true
[ "$helper_status" -eq 0 ] && helper_ok=true
{
  echo "app_ok=$app_ok"
  echo "daemon_ok=$daemon_ok"
  echo "helper_ok=$helper_ok"
} >> "$GITHUB_OUTPUT"
exit 0
