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
# Match the cmux-tui-artifacts job environment so the extracted gate stays identical to CI.
export CARGO_INCREMENTAL=0 CMUX_GHOSTTY_SRC="" GHOSTTY_ZIG_SOURCE=ghostty-next
unset CMUX_ZIG ZIG
log_dir="${RUNNER_TEMP:-$(mktemp -d)}"
# Bound cargo's parallel rustc by memory, the rule scripts/ci/cargo-groups.sh uses: one job per
# CARGO_GROUPS_GIB_PER_GROUP (4) GiB of the lesser of the cgroup's memory.max and MemAvailable, at least 1, at most
# the cores. Unbounded, every core ran a test-profile rustc (the acpmux and cmux-tui-core lib tests) in a 14 GiB pool
# slot and the kernel SIGKILLed them (cmux-tui artifacts run 46151055767, job 140997699588). An explicit
# CARGO_BUILD_JOBS wins; no cap and plenty of memory keeps every core.
if [[ -z "${CARGO_BUILD_JOBS:-}" ]]; then
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  budget=""
  rel=$(awk -F: '$1 == "0" { print $3; exit }' /proc/self/cgroup 2>/dev/null || true)
  p="/sys/fs/cgroup${rel%/}"
  while [[ -n "$rel" ]]; do
    v=$(cat "$p/memory.max" 2>/dev/null || true)
    if [[ "$v" =~ ^[0-9]+$ ]] && { [[ -z "$budget" ]] || ((v / 1073741824 < budget)); }; then budget=$((v / 1073741824)); fi
    [[ "$p" == /sys/fs/cgroup ]] && break
    p="${p%/*}"; [[ "$p" == /sys/fs/cgroup* ]] || break
  done
  avail=$(awk '$1 == "MemAvailable:" { print int($2 / 1048576); exit }' /proc/meminfo 2>/dev/null || true)
  if [[ -n "$avail" ]] && { [[ -z "$budget" ]] || ((avail < budget)); }; then budget=$avail; fi
  if [[ -n "$budget" ]]; then
    jobs=$((budget / ${CARGO_GROUPS_GIB_PER_GROUP:-4})); ((jobs >= 1)) || jobs=1; ((jobs <= cores)) || jobs=$cores
    export CARGO_BUILD_JOBS=$jobs
    echo "cmux_next tests: ${budget} GiB of memory holds CARGO_BUILD_JOBS=$jobs of $cores cores"
  fi
fi
log="$log_dir/cmux-next-tests.txt"

# Only the members whose sources name cmux_next_ (the filter matches the
# test path, so no other member can hold one): skips the test binaries of
# every other member. Falls back to --workspace.
read -r -a members <<<"$(../scripts/ci/cmux-next-daemon-test-packages.sh)"
echo "cmux_next_ test members: ${members[*]}"
# One job per 6 GiB of a memory-capped runner (scripts/ci/cargo-mem-jobs.sh; -j4 in 14 GiB was still SIGKILLed): a `cmux-linux` pool slot shows 8
# threads under memory.max 14 GiB, and the test compile at -j8 had the kernel SIGKILL the cmux-tui-core, acpmux
# and cmux-tui rustc on all three attempts (job 140997699588, run 46151055767, 2026-11-28), so no tree got its
# daemon-tests marker and the feat-cmux-next channel stayed at 02b3b98c from 03:41Z. A caller's CARGO_BUILD_JOBS wins.
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(bash ../scripts/ci/cargo-mem-jobs.sh || true)}"
if [[ -n "$CARGO_BUILD_JOBS" ]]; then export CARGO_BUILD_JOBS; echo "CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS"; else unset CARGO_BUILD_JOBS; fi
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
  # A rustc error[E...] is the source, not the runner: every attempt fails it the same way, so it is never
  # retried. Job 141050286394 (run 46168107258, 2026-11-28) recompiled an E0063 twice at fewer jobs and hit
  # the step's 65-minute limit: the red came an hour late and no tree got its marker meanwhile.
  if [[ "$status" -ne 0 ]] && grep -qE '^error\[E[0-9]+\]' "$log"; then
    echo "::error::cmux_next_ daemon tests: the code does not compile (the rustc error above); not retried" >&2
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
    # A rustc the kernel SIGKILLed (no error[...] line) fails the same way at the same -j: halve the jobs.
    if grep -q 'signal: 9, SIGKILL' "$log"; then
      jobs="${CARGO_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
      export CARGO_BUILD_JOBS=$(((jobs + 1) / 2))
      echo "cmux_next_ daemon tests: a rustc was SIGKILLed (out of memory); attempt $((attempt + 1)) runs CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS" >&2
    fi
    echo "cmux_next_ daemon tests failed on attempt $attempt/3; retrying Cargo registry and build fetches" >&2
    sleep $((attempt * 10))
  fi
done
if [[ "$status" -ne 0 ]]; then
  echo "::error::cmux_next_ daemon tests failed after 3 attempts" >&2
  exit "$status"
fi
