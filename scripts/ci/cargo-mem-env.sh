# shellcheck shell=bash
# cargo-mem-env.sh: source before a single `cargo build` on a CI runner whose memory may be capped:
#   source "$GITHUB_WORKSPACE/scripts/ci/cargo-mem-env.sh"
# 1. CARGO_BUILD_JOBS: one job per 6 GiB of the slot's memory.max (scripts/ci/cargo-mem-jobs.sh); a caller's wins.
# 2. When memory capped that count (and the caller set no CARGO_BUILD_JOBS), the giant rustc (acpmux, cmux_tui,
#    cmux_tui_core) compile one at a time behind scripts/ci/cargo-giant-lock.sh, as cargo-groups.sh does (#65281).
#    -j2 alone was not enough: in a 14 GiB cmux-linux slot cargo still started the cmux_tui lib rustc on acpmux's
#    rmeta while acpmux's codegen ran, and the kernel SIGKILLed both (Cloudflare relay journey build, run
#    46172359390, job 141071898378, 2026-11-28: CARGO_BUILD_JOBS=2, acpmux 18:24, cmux-tui 18:26, both killed
#    18:32), so the staging journey and the production relay deploy never ran.
# CARGO_GROUPS_GIANTS overrides the crate list; CARGO_GROUPS_NO_GIANT_LOCK=1 turns the lock off.
# Test: scripts/ci/tests/cargo-mem-env.test.sh.

__cargo_mem_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__cargo_mem_caller="${CARGO_BUILD_JOBS:-}"
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(bash "$__cargo_mem_dir/cargo-mem-jobs.sh" 2>/dev/null || true)}"
if [[ -n "$CARGO_BUILD_JOBS" ]]; then
  export CARGO_BUILD_JOBS
  echo "CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS"
  if [[ -z "$__cargo_mem_caller" && -z "${CARGO_GROUPS_NO_GIANT_LOCK:-}" ]] && command -v flock >/dev/null 2>&1; then
    export CARGO_GROUPS_GIANTS="${CARGO_GROUPS_GIANTS:-acpmux cmux_tui cmux_tui_core}"
    export CARGO_GROUPS_GIANT_LOCK="${CARGO_GROUPS_GIANT_LOCK:-$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cargo-giant.XXXXXX")}"
    if [[ "${RUSTC_WRAPPER:-}" != "$__cargo_mem_dir/cargo-giant-lock.sh" ]]; then
      export CARGO_GROUPS_INNER_WRAPPER="${RUSTC_WRAPPER:-}"
      export RUSTC_WRAPPER="$__cargo_mem_dir/cargo-giant-lock.sh"
    fi
    echo "cargo-mem-env: giants ($CARGO_GROUPS_GIANTS) compile one at a time"
  fi
else
  unset CARGO_BUILD_JOBS
fi
unset __cargo_mem_dir __cargo_mem_caller
