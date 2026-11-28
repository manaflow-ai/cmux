#!/usr/bin/env bash
# One big member's cmux_next_ daemon tests on the pull request: ci/steps.toml's cmux-next-acpmux,
# cmux-next-tui-core and cmux-next-tui steps. The same cargo test the post-merge gate (cmux-next-daemon-tests) runs for
# that member, with the gate's build env, so the gate's saved target (scripts/ci/cmux-tui-test-target.sh, from the last
# feat-cmux-next push) is fresh here and only what the pull request changed compiles.
#
#   scripts/ci/cmux-next-member-tests.sh MEMBER_DIR     (MEMBER_DIR under cmux-tui/, e.g. crates/acpmux)
#   scripts/ci/cmux-next-member-tests.sh MEMBER_DIR TEST FILTER
#                                         one of the member's gate test targets only, and only the gate tests whose
#                                         path holds FILTER (FILTER starts within cmux_next_'s module path, e.g.
#                                         `it idle_wakeups::cmux_next_`: ci/steps.toml cmux-next-idle-wakeups)
#
# Fails when a test fails, when nothing compiles, and when the filter runs no test (as the gate does). A recognized
# Cargo fetch failure is retried twice, as in the gate.
set -euo pipefail
member="${1:?usage: $0 MEMBER_DIR [TEST FILTER]}"
only_test="${2:-}"
filter="${3:-cmux_next_}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo/cmux-tui"
read -r -a args <<<"$(../scripts/ci/cmux-next-daemon-test-packages.sh "$member")"
if [[ -n "$only_test" ]]; then
  # The gate's own target only, so the gate's saved target covers it and a red here is a red there.
  [[ " ${args[*]} " == *" --test $only_test "* ]] || { echo "::error::$member's gate targets (${args[*]}) have no --test $only_test"; exit 2; }
  [[ "$filter" == *cmux_next_* ]] || { echo "::error::filter $filter selects tests the gate does not run (it holds no cmux_next_)"; exit 2; }
  args=("${args[0]}" "${args[1]}" --test "$only_test")
fi
channel="$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' rust-toolchain.toml)"
rustup toolchain install "$channel" --profile minimal --component clippy,rustfmt
# cmux-next-daemon-tests' env, word for word: the saved target's fingerprints hold it.
export CARGO_NET_RETRY=10 CARGO_HTTP_TIMEOUT=120 CARGO_HTTP_MULTIPLEXING=false TMPDIR=/tmp CMUX_GHOSTTY_SRC=""
export GHOSTTY_ZIG_SOURCE=ghostty-next CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=2
# MEM_FIT_JOBS: start at the job count this slot's memory holds (cargo-mem-jobs.sh, 6 GiB a job) when that is under 2.
# The job count is not in rustc's fingerprints, so the saved target still covers it. At 2 jobs on a small slot the
# acpmux and cmux-tui-core rustc OOM'd side by side, and the one-job rerun after the kill then ran past the step's
# 2700 s (cmux#65293 run 46176617995 job 141076778482): the time spent before the kill is wasted.
fit="$(env -u CARGO_BUILD_JOBS bash ../scripts/ci/cargo-mem-jobs.sh 2>/dev/null || true)"
if [[ "$fit" =~ ^[0-9]+$ ]] && ((fit < CARGO_BUILD_JOBS)); then
  echo "cmux_next_ tests: this slot's memory holds CARGO_BUILD_JOBS=$fit"
  export CARGO_BUILD_JOBS=$fit
fi
unset CMUX_ZIG ZIG
../scripts/ci/cmux-tui-test-target.sh restore
home="$(mktemp -d /tmp/acpmux-home.XXXXXX)"
export ACPMUX_HOME="$home" ACPMUX_SOCKET=""
log="$(mktemp /tmp/cmux-next-member-tests.XXXXXX.txt)"
echo "cmux_next_ tests of $member: ${args[*]}"
start=$SECONDS
status=1
# oom_kills: the kernel's OOM kill count (/proc/vmstat oom_kill), or nothing off Linux (cargo-groups.sh's reader).
oom_kills() { awk '$1 == "oom_kill" { print $2; exit }' "${MEMBER_TESTS_VMSTAT:-/proc/vmstat}" 2>/dev/null || true; }
oom_rerun_done=0
for attempt in 1 2 3; do
  oom_before=$(oom_kills)
  # set -e would end the script on a failing pipeline: keep it off for the test so the retry, the timing line and the
  # daemon cleanup below still run.
  set +e
  cargo test "${args[@]}" --locked "$filter" 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -ne 0 ] && python3 ../scripts/cmux-next/cargo-locks.py explain "$log"; then break; fi
  if [ "$status" -eq 0 ]; then
    grep -qE 'test result: ok\. [1-9][0-9]* passed' "$log" && break
    echo "::error::cargo test ran no cmux_next_ test of $member (the filter matched nothing)"
    status=1
    break
  fi
  # OOM_RERUN_ONE_JOB: acpmux (936k lines) and cmux-tui-core (674k) compile at once when a change reaches both (a
  # Cargo.lock change does), and at CARGO_BUILD_JOBS=2 their two rustc outgrow a w4b pool slot's memory: the kernel
  # SIGKILLed the acpmux rustc twice on cmux#59165 (run 46165310642, jobs 141041525983 and 141052004120, 2026-11-28),
  # and "could not compile" below read it as a compile error. cargo lets the survivor finish, so one rerun at one job
  # keeps its units and compiles the killed crate alone (cargo-groups.sh's OOM_RERUN_ALONE). Once; a second kill fails.
  if [ "$oom_rerun_done" -eq 0 ] && grep -q 'signal: 9, SIGKILL' "$log"; then
    oom_now=$(oom_kills)
    if [ -z "$oom_before" ] || [ -z "$oom_now" ] || [ "$oom_now" -gt "$oom_before" ]; then
      echo "::warning::cmux_next_ tests of $member: the kernel OOM-killed a rustc (oom_kill ${oom_before:-?} -> ${oom_now:-?}); rerunning once at CARGO_BUILD_JOBS=1, its finished units kept"
      export CARGO_BUILD_JOBS=1
      oom_rerun_done=1
      continue
    fi
  fi
  if grep -qE 'test result: FAILED|error(\[E[0-9]+\])?: could not compile|^error\[E[0-9]+\]' "$log" \
    || ! grep -qiE 'spurious network error|failed to download|unable to update registry|failed to (fetch|get|query)|could not resolve host|couldn.t resolve host|connection (reset|refused|timed out)|operation timed out|ssl (connect )?error|http2 error|early eof|download of .* failed|registry index .*(failed|error)' "$log"; then
    echo "::error::cmux_next_ tests of $member failed with a result that is not a Cargo fetch failure; not retrying"
    break
  fi
  [ "$attempt" -lt 3 ] && sleep $((attempt * 10))
done
echo "cmux_next_ tests of $member: cargo test took $((SECONDS - start)) s (exit $status)"
case "$(head -c 300 "$(command -v cargo)" 2>/dev/null | tr -d '\0')" in
  *RUSTC_WRAPPER=*sccache*) sccache --show-stats || true ;;
esac
# End the daemon of this home and its agents, then delete the home (a path this script made).
acpmux="$(command -v acpmux || true)"
[ -z "$acpmux" ] || env -u ACPMUX_SOCKET ACPMUX_HOME="$home" "$acpmux" daemon shutdown --end-agents || true
rm -rf "$home" "$log"
exit "$status"
