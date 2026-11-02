#!/usr/bin/env bash
# One cmux-tui Rust test, run alone on an idle Mac: a fleet measurement step (class exclusive,
# label measure: nothing else runs on the host while it runs) builds one crate's tests and runs
# the one filter it names, with the host's load before and after. It answers "does this test
# fail with no other load on the Mac?", which a shared ci-step host (8 to 21 load on 10 cores)
# cannot: the acpmux harness CPU-class question (cmux #30057, lead 2026-11-01 04:30Z).
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/rust-test-bench.sh \
#     --ref SHA --arg CRATE --arg FILTER [--arg source=SHA] [--arg target=lib|test:NAME] [--arg ignored=yes] \
#     --artifact artifacts/rust-test-bench/output.txt
#
# CRATE    a package of the cmux-tui workspace, e.g. acpmux.
# FILTER   one libtest name filter (a substring of the test path), e.g.
#          hub::steer_end::race_tests::an_unsent_steer_probe_sequence. A filter that runs no
#          test fails the step.
# source=SHA
#          run the tests of this commit instead of the step's own. The step's --ref must carry
#          this script (a feat-cmux-next commit), so a branch or a scratch probe is measured
#          this way: --ref the feat-cmux-next tip, source= the commit to test.
# target=lib|test:NAME
#          only the crate's library unit tests, or only its integration test NAME (tests/NAME.rs);
#          default: both (`--lib --tests`), no doc tests.
# ignored=yes
#          also run `#[ignore]`d tests the filter names (`--include-ignored`): a measurement
#          written as an ignored test, which no suite runs.
#
# Output: the test's own output (--nocapture, one test thread) in the step log and the artifact,
# then RUST-TEST-BENCH lines: the measured tree, the host, `vm.loadavg` and the processes over
# 5 % CPU before and after the run, the test count and cargo's exit. The step fails when the
# build fails, when the filter runs no test, or when a test fails; it never retries. The checkout
# goes back to the step's own commit when the script ends.
set -euo pipefail
export LC_ALL=C

# The whole script is one function, read before it runs: source= replaces the checkout's files,
# this one included.
main() {
  # shellcheck source-path=SCRIPTDIR source=../cmux-next/lib/fleet-only.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"

  # --- Arguments (checked before anything else runs) ----------------------
  local usage="usage: rust-test-bench.sh CRATE FILTER [source=SHA] [target=lib|test:NAME] [ignored=yes]"
  [[ $# -ge 2 ]] || { echo "$usage" >&2; exit 2; }
  local a
  for a in "$@"; do
    [[ "$a" != *$'\n'* && "$a" != *$'\r'* ]] || { echo "rust-test-bench.sh: an argument has a line break" >&2; exit 2; }
  done
  local crate=$1 filter=$2
  shift 2
  [[ "$crate" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
    { echo "rust-test-bench.sh: CRATE must be a cmux-tui package name (got '$crate')" >&2; exit 2; }
  [[ "$filter" =~ ^[A-Za-z0-9_][A-Za-z0-9_:]*$ ]] ||
    { echo "rust-test-bench.sh: FILTER must be a Rust test path (letters, digits, _ :; got '$filter')" >&2; exit 2; }
  local source_sha="" target="" ignored="" arg key seen=" "
  for arg in "$@"; do
    key=${arg%%=*}
    if [[ "$arg" != *=?* || "$seen" == *" $key "* ]]; then
      echo "rust-test-bench.sh: bad or repeated argument '$arg'; $usage" >&2; exit 2
    fi
    seen+="$key "
    case "$key" in
      source) source_sha=${arg#source=} ;;
      target) target=${arg#target=} ;;
      ignored) ignored=${arg#ignored=} ;;
      *) echo "rust-test-bench.sh: unknown argument '$arg'; $usage" >&2; exit 2 ;;
    esac
  done
  [[ -z "$source_sha" || "$source_sha" =~ ^[0-9a-f]{40}$ ]] ||
    { echo "rust-test-bench.sh: source= takes a full 40-character commit sha (got '$source_sha')" >&2; exit 2; }
  local ignored_args=()
  case "$ignored" in
    "") ;;
    yes) ignored_args=(--include-ignored) ;;
    *) echo "rust-test-bench.sh: ignored= takes yes (got '$ignored')" >&2; exit 2 ;;
  esac
  local target_args=(--lib --tests)
  case "$target" in
    "") ;;
    lib) target_args=(--lib) ;;
    test:*)
      [[ "${target#test:}" =~ ^[a-z0-9_][a-z0-9_-]*$ ]] ||
        { echo "rust-test-bench.sh: target=test:NAME takes an integration test name (got '$target')" >&2; exit 2; }
      target_args=(--test "${target#test:}") ;;
    *) echo "rust-test-bench.sh: target= takes lib or test:NAME (got '$target')" >&2; exit 2 ;;
  esac

  cmux_next_require_fleet rust-test-bench.sh "cargo test" "none (a measurement)" \
    "cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/rust-test-bench.sh --ref SHA --arg CRATE --arg FILTER"

  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  cd "$root"
  step_ref="$(git rev-parse HEAD)"
  local out="$root/artifacts/rust-test-bench"
  rm -rf "$out"
  mkdir -p "$out"
  report="$out/output.txt"
  # The step's own PATH as the worker gives it (the rustup shim and the fleet's pinned zig first),
  # as cmux-tui-rust-check.sh uses it: a Homebrew cargo or zig ahead of them would build with the
  # wrong toolchain.
  # Its own target directory in the step's checkout: nothing shared with another step.
  export CARGO_TARGET_DIR="$root/.build/rust-test-bench-target"

  # --- The measured tree --------------------------------------------------
  trap back_to_step_ref EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  if [[ -n "$source_sha" ]]; then
    local depth=()
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
    if ! git cat-file -e "$source_sha^{commit}" 2>/dev/null; then
      git fetch -q --no-tags ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$source_sha" ||
        { echo "rust-test-bench.sh: could not fetch $source_sha" >&2; exit 3; }
    fi
    git checkout -q --detach "$source_sha"
  fi
  # ghostty-vt-sys builds libghostty-vt from ghostty-next; a step's checkout has empty submodules.
  git submodule update --init --depth 1 ghostty-next >/dev/null ||
    { echo "rust-test-bench.sh: git submodule update --init ghostty-next failed" >&2; exit 3; }
  [[ -f cmux-tui/Cargo.toml ]] || { echo "rust-test-bench.sh: no cmux-tui/Cargo.toml at $(git rev-parse HEAD)" >&2; exit 2; }

  note "RUST-TEST-BENCH tree: $(git rev-parse HEAD) (step commit $step_ref)"
  note "RUST-TEST-BENCH test: -p $crate ${target_args[*]} -- $filter"
  note "RUST-TEST-BENCH host: $(hostname -s), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, macOS $(sw_vers -productVersion)"

  # --- Build ---------------------------------------------------------------
  cd "$root/cmux-tui"
  local t0=$SECONDS build_status
  set +e
  # Output goes to the step log as it comes, so a long build is not stopped as a silent one.
  cargo test --locked -p "$crate" "${target_args[@]}" --no-run 2>&1 | tee "$out/build.log"
  local -a build_pipe=("${PIPESTATUS[@]}")
  set -e
  build_status=${build_pipe[0]}
  [[ ${build_pipe[1]} -eq 0 ]] || { echo "rust-test-bench.sh: could not write $out/build.log" >&2; exit 3; }
  if [[ $build_status -ne 0 ]]; then
    grep -E "^error" "$out/build.log" | sort -u | head -40 || true
    note "RUST-TEST-BENCH build: failed (exit $build_status) after $((SECONDS - t0)) s"
    exit 1
  fi
  note "RUST-TEST-BENCH build: $((SECONDS - t0)) s"

  # --- Run -----------------------------------------------------------------
  host_load before
  t0=$SECONDS
  local status
  set +e
  cargo test --locked -p "$crate" "${target_args[@]}" -- "$filter" ${ignored_args[@]+"${ignored_args[@]}"} --nocapture --test-threads=1 2>&1 |
    tee "$out/test.log" | tee -a "$report"
  local -a test_pipe=("${PIPESTATUS[@]}")
  set -e
  status=${test_pipe[0]}
  [[ ${test_pipe[1]} -eq 0 && ${test_pipe[2]} -eq 0 ]] ||
    { echo "rust-test-bench.sh: could not write the test log" >&2; exit 3; }
  host_load after
  # Each test binary prints "test result: ... N passed; M failed"; the sum is the run.
  local ran
  ran="$(sed -nE 's/^test result: [a-zA-Z]+\. ([0-9]+) passed; ([0-9]+) failed.*/\1 \2/p' "$out/test.log" |
    awk '{ n += $1 + $2 } END { print n + 0 }')"
  note "RUST-TEST-BENCH result: cargo exit $status, $ran test(s), $((SECONDS - t0)) s"
  # A test binary that crashed prints no "test result:" line: cargo's exit says so, not "no test".
  if [[ "$ran" -eq 0 && "$status" -eq 0 ]]; then
    note "RUST-TEST-BENCH result: no test matched $filter"
    exit 1
  fi
  exit "$status"
}

note() { printf '%s\n' "$*" | tee -a "$report"; }

# The host's load and the processes over 5 % CPU (ps's lifetime-averaged %cpu is not used: two
# `top` samples, the second one read).
host_load() {
  note "RUST-TEST-BENCH load $1: $(sysctl -n vm.loadavg)"
  local busy
  busy="$(top -l 2 -s 1 -stats cpu,command -o cpu 2>/dev/null |
    awk '/^%CPU/ { block++; next } block == 2 && $1 + 0 > 5 { printf "%s=%s ", $2, $1 }' | head -c 600)" || true
  note "RUST-TEST-BENCH busy $1: ${busy:-none over 5 %}"
}

# Put the checkout back at the step's own commit (source= changed it).
back_to_step_ref() {
  [[ -n "${step_ref:-}" ]] || return 0
  git checkout -q -f --detach "$step_ref" >/dev/null 2>&1 || true
}

report=/dev/null
step_ref=""
main "$@"; exit $?
