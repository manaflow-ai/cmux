#!/usr/bin/env bash
# scripts/ci/cmux-next-member-tests.sh OOM_RERUN_ONE_JOB: a rustc the kernel OOM-killed (cmux#59165, run 46165310642)
# reruns once at CARGO_BUILD_JOBS=1 instead of failing as a compile error; a second kill, or a SIGKILL with no OOM kill,
# still fails. Runs the real script in a scratch tree with stub cargo, rustup and helper scripts.
# Run: bash tests/test_ci_member_tests_oom_rerun.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d /tmp/member-tests-oom.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/repo/scripts/ci" "$scratch/repo/scripts/cmux-next" "$scratch/repo/cmux-tui" "$scratch/bin"
cp "$here/scripts/ci/cmux-next-member-tests.sh" "$here/scripts/ci/cargo-mem-jobs.sh" "$scratch/repo/scripts/ci/"
# A fake cgroup v2 tree: the slot's memory.max is MEM_GIB (cargo-mem-jobs.sh reads it, 6 GiB a job).
mkdir -p "$scratch/cg/slot"; echo "0::/slot" > "$scratch/proc-cgroup"
printf '#!/bin/sh\necho "-p cmux-tui --test it"\n' > "$scratch/repo/scripts/ci/cmux-next-daemon-test-packages.sh"
printf '#!/bin/sh\nexit 0\n' > "$scratch/repo/scripts/ci/cmux-tui-test-target.sh"
printf 'import sys\nsys.exit(1)\n' > "$scratch/repo/scripts/cmux-next/cargo-locks.py"
printf '[toolchain]\nchannel = "1.95.0"\n' > "$scratch/repo/cmux-tui/rust-toolchain.toml"
printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/rustup"
# Stub cargo: each call appends its CARGO_BUILD_JOBS to calls; the first KILLS calls die as an OOM-killed rustc
# (bumping the fake vmstat's oom_kill when BUMP=1), the rest pass one test.
cat > "$scratch/bin/cargo" <<'STUB'
#!/usr/bin/env bash
echo "${CARGO_BUILD_JOBS:-unset}" >> "$STUB_DIR/calls"
n=$(wc -l < "$STUB_DIR/calls")
if [ "$n" -le "$KILLS" ]; then
  [ "$BUMP" = 1 ] && echo "oom_kill $n" > "$STUB_DIR/vmstat"
  echo "error: could not compile \`acpmux\` (lib)"
  echo "  process didn't exit successfully: rustc --crate-name acpmux (signal: 9, SIGKILL: kill)"
  exit 101
fi
echo "test result: ok. 1 passed; 0 failed"
STUB
chmod +x "$scratch"/bin/* "$scratch"/repo/scripts/ci/*.sh
fail=0
run() { # NAME KILLS BUMP WANT_EXIT WANT_CALLS [MEM_GIB]
  rm -f "$scratch/calls"; echo "oom_kill 0" > "$scratch/vmstat"
  echo $(( ${6:-64} * 1073741824 )) > "$scratch/cg/slot/memory.max"
  set +e
  PATH="$scratch/bin:$PATH" STUB_DIR="$scratch" KILLS="$2" BUMP="$3" MEMBER_TESTS_VMSTAT="$scratch/vmstat" \
    CARGO_GROUPS_CGROUP_ROOT="$scratch/cg" CARGO_GROUPS_PROC_CGROUP="$scratch/proc-cgroup" \
    bash "$scratch/repo/scripts/ci/cmux-next-member-tests.sh" crates/cmux-tui > "$scratch/out" 2>&1
  local got=$?
  set -e
  local calls; calls="$(tr '\n' ' ' < "$scratch/calls")"
  if [ "$got" -ne "$4" ] || [ "$calls" != "$5" ]; then
    echo "FAIL $1: exit $got (want $4), cargo calls [$calls] (want [$5])"; sed 's/^/  | /' "$scratch/out"; fail=1
  else
    echo "ok   $1"
  fi
}
run "an OOM kill reruns once at one job and passes" 1 1 0 "2 1 "
run "a second OOM kill fails" 2 1 101 "2 1 "
run "a SIGKILL with no OOM kill is not rerun" 1 0 101 "2 "
run "a slot whose memory holds one job starts at one job" 0 0 0 "1 " 8
run "a slot whose memory holds two jobs keeps two" 0 0 0 "2 " 16
exit "$fail"
