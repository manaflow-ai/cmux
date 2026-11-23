#!/usr/bin/env bash
# The cmux_next_ daemon tests: the gate the feat-cmux-next acpmux channel waits on (a pass writes
# tree/<key>/daemon-tests.json, and point-feat-channel moves only to a tree that has it).
#
# One command, so whatever runs the gate runs the same thing: the GitHub job
# (cmux-tui-artifacts.yml "cargo test cmux_next_") and our own machines, through the channel keeper
# (scripts/ci/cmux_tui_channel_keeper.py) or `cmux-ci test --ref SHA -- scripts/ci/cmux-next-daemon-tests.sh`.
# Leo, 2026-11-23, after the job's 60-minute limit held the channel: "but why is it a job. we own/should own
# the in-between. like ci v2. we own the end to end."
#
# Run from the repository root or cmux-tui/. The caller gives the tests a home of their own
# (ACPMUX_HOME, an empty ACPMUX_SOCKET, a short TMPDIR) and has zig, the ghostty-next submodule and the
# pinned Rust ready, as the workflow's earlier steps do.
# Exit 0: at least one cmux_next_ test ran and all passed. Anything else is red.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root/cmux-tui"
log_dir="${RUNNER_TEMP:-$(mktemp -d)}"
log="$log_dir/cmux-next-tests.txt"

# Only the members whose sources name cmux_next_ (the filter matches the
# test path, so no other member can hold one): skips the test binaries of
# every other member. Falls back to --workspace.
read -r -a members <<<"$(../scripts/ci/cmux-next-daemon-test-packages.sh)"
echo "cmux_next_ test members: ${members[*]}"
status=1
for attempt in 1 2 3; do
  rm -f "$log"
  # One cargo invocation: a separate `-- --list` pass rebuilt acpmux and
  # cmux-tui before the real run (2m39s, run 38014219284). The filter
  # must still match tests: a run that passed none is red.
  status=0
  cargo test "${members[@]}" --locked cmux_next_ 2>&1 | tee "$log" || status=$?
  # A stale Cargo.lock: named with its fix (cargo-locks.py explain), never retried.
  if [[ "$status" -ne 0 ]] && python3 ../scripts/cmux-next/cargo-locks.py explain "$log"; then
    exit "$status"
  fi
  if [[ "$status" -eq 0 ]]; then
    if grep -qE 'test result: ok\. [1-9][0-9]* passed' "$log"; then
      break
    fi
    echo "::error::cargo test ran no cmux_next_ test (the filter matched nothing)" >&2
    exit 1
  fi
  if [[ "$attempt" -lt 3 ]]; then
    echo "cmux_next_ daemon tests failed on attempt $attempt/3; retrying Cargo registry and build fetches" >&2
    sleep $((attempt * 10))
  fi
done
if [[ "$status" -ne 0 ]]; then
  echo "::error::cmux_next_ daemon tests failed after 3 attempts" >&2
  exit "$status"
fi
