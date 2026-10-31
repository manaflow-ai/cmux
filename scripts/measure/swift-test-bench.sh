#!/usr/bin/env bash
# One swift-test benchmark, measured alone: a fleet measurement step (class
# exclusive, label measure: nothing else runs on the host while it measures)
# builds a Swift package's tests once, then runs the one filter it names. The
# test's own output (its print lines, e.g. a benchmark's numbers) is in the step
# log and in the artifact.
#
#   cmux-ci run --class exclusive --script scripts/measure/swift-test-bench.sh --ref SHA \
#     --arg PACKAGE --arg FILTER [--arg source=SHA] [--arg restore_from=SHA --arg restore=PATH,PATH] \
#     [--arg config=release] [--arg enable=CMUX_<NAME>_BENCH] \
#     --artifact artifacts/swift-test-bench/output.txt
#
# PACKAGE  a package directory under Packages/ or cmux-next-ios/ (it holds a
#          Package.swift), e.g. cmux-next-ios/CmuxMobileKit.
# FILTER   one `swift test --filter`, e.g.
#          TerminalInputThroughputTests/keystrokeThroughputAt500msRTT. A filter
#          that runs no test fails the step.
# source=SHA
#          measure the tree of this commit instead of the step's own. The step's
#          --ref must carry this script (a feat-cmux-next commit), so a pull
#          request that branched before the script landed is measured this way:
#          --ref the feat-cmux-next tip, source= the pull request's head.
# restore_from=SHA restore=PATH[,PATH...]
#          before building, check out these files of PACKAGE (paths relative to
#          it) as they are at SHA, keeping the rest of the measured tree: the
#          "before" half of an A/B whose harness exists only at the head. Each
#          PATH must be a file at SHA.
# config=debug|release
#          build and run the tests in this configuration; default debug. release is
#          package-test-lane.sh's release suite build: `-c release` with -enable-testing
#          (@testable imports), -DDEBUG and CopyPropagation off. A benchmark of optimized
#          code (MainTurnMeterBench) needs it.
# enable=CMUX_<NAME>_BENCH
#          set this one benchmark switch to 1 for the test run: a bench suite that
#          is disabled unless its switch is set (MainTurnMeterBench: CMUX_MAIN_TURN_BENCH).
#
# The step fails when the build fails, when the filter runs no test, or when a
# test fails; it never retries. The checkout goes back to the step's own commit
# when the script ends.
set -euo pipefail
# Byte ranges in the argument checks ([A-Z] matches only ASCII letters), as the controller's.
export LC_ALL=C

# The whole script is one function, read before it runs: source= replaces the
# checkout's files, this one included.
main() {
  # shellcheck source-path=SCRIPTDIR source=../cmux-next/lib/fleet-only.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"

  # --- Arguments (checked before anything else runs) ----------------------
  local usage="usage: swift-test-bench.sh PACKAGE FILTER [source=SHA] [restore_from=SHA restore=PATH[,PATH...]] [config=debug|release] [enable=CMUX_<NAME>_BENCH]"
  [[ $# -ge 2 ]] || { echo "$usage" >&2; exit 2; }
  local a
  for a in "$@"; do
    [[ "$a" != *$'\n'* && "$a" != *$'\r'* ]] || { echo "swift-test-bench.sh: an argument has a line break" >&2; exit 2; }
  done
  local package=$1 filter=$2
  shift 2
  if ! [[ "$package" =~ ^(Packages|cmux-next-ios)/[A-Za-z0-9_][A-Za-z0-9_./-]*$ ]] ||
    [[ "/$package/" == */../* || "/$package/" == */./* || "$package" == *//* ]]; then
    echo "swift-test-bench.sh: PACKAGE must be a directory under Packages/ or cmux-next-ios/ (got '$package')" >&2; exit 2
  fi
  package=${package%/}
  if ! [[ "$filter" =~ ^[A-Za-z0-9_][A-Za-z0-9_./:-]*$ ]] || [[ "$filter" == *. || "$filter" == */ ]]; then
    echo "swift-test-bench.sh: FILTER must be a test name such as Suite/test (letters, digits, _ . / : -; got '$filter')" >&2; exit 2
  fi
  local source_sha="" restore_sha="" restore_list="" config="" bench_switch="" arg key seen=" "
  for arg in "$@"; do
    key=${arg%%=*}
    # Each key at most once, and never with an empty value.
    if [[ "$arg" != *=?* || "$seen" == *" $key "* ]]; then
      echo "swift-test-bench.sh: bad or repeated argument '$arg'; $usage" >&2; exit 2
    fi
    seen+="$key "
    case "$key" in
      source) source_sha=${arg#source=} ;;
      restore_from) restore_sha=${arg#restore_from=} ;;
      restore) restore_list=${arg#restore=} ;;
      config) config=${arg#config=} ;;
      enable) bench_switch=${arg#enable=} ;;
      *) echo "swift-test-bench.sh: unknown argument '$arg'; $usage" >&2; exit 2 ;;
    esac
  done
  if [[ -n "$config" && "$config" != debug && "$config" != release ]]; then
    echo "swift-test-bench.sh: config= takes debug or release (got '$config')" >&2; exit 2
  fi
  # One benchmark switch only, never another variable (a token, a path).
  if [[ -n "$bench_switch" ]] && ! [[ "$bench_switch" =~ ^CMUX_[A-Z0-9]+(_[A-Z0-9]+)*_BENCH$ ]]; then
    echo "swift-test-bench.sh: enable= takes one benchmark switch CMUX_<NAME>_BENCH (got '$bench_switch')" >&2; exit 2
  fi
  # Release: the package-test-lane.sh flags (its CMUX_SWIFT_SUITE_CONFIGURATION=release), so a bench
  # measures the same build as a release suite there: @testable imports need -enable-testing, DEBUG stays
  # defined for #if DEBUG test helpers, and the Xcode 26.6 optimizer's CopyPropagation crash is avoided.
  local config_args=()
  [[ "$config" != release ]] ||
    config_args=(-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=copy-propagation)
  local sha
  for sha in "$source_sha" "$restore_sha"; do
    [[ -z "$sha" || "$sha" =~ ^[0-9a-f]{40}$ ]] ||
      { echo "swift-test-bench.sh: source= and restore_from= take a full 40-character commit sha (got '$sha')" >&2; exit 2; }
  done
  if [[ -n "$restore_sha" && -z "$restore_list" ]] || [[ -z "$restore_sha" && -n "$restore_list" ]]; then
    echo "swift-test-bench.sh: restore_from= and restore= go together" >&2; exit 2
  fi
  local restore_paths=() path
  if [[ -n "$restore_list" ]]; then
    local items=()
    IFS=, read -r -a items <<< "$restore_list,"
    for path in ${items[@]+"${items[@]}"}; do
      if ! [[ "$path" =~ ^[A-Za-z0-9_][A-Za-z0-9_.+/-]*$ ]] || [[ "/$path/" == */../* || "/$path/" == */./* || "$path" == */ || "$path" == *//* ]]; then
        echo "swift-test-bench.sh: restore= takes file paths relative to PACKAGE, comma-separated (got '$path')" >&2; exit 2
      fi
      restore_paths+=("$package/$path")
    done
    [[ ${#restore_paths[@]} -gt 0 ]] || { echo "$usage" >&2; exit 2; }
  fi

  cmux_next_require_fleet swift-test-bench.sh "swift build and swift test" "none (a measurement)" \
    "cmux-ci run --class exclusive --script scripts/measure/swift-test-bench.sh --ref SHA --arg PACKAGE --arg FILTER"

  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$root"
  step_ref="$(git rev-parse HEAD)"
  local out="$root/artifacts/swift-test-bench" work="$root/.build/swift-test-bench"
  rm -rf "$out" "$work"
  mkdir -p "$out" "$work"
  report="$out/output.txt"

  # Steps run with a per-step HOME; Homebrew tools live outside it.
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

  # The Xcode, chosen by the step's own (reviewed) tree before any switch.
  if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    GITHUB_ENV="$work/xcode.env" CMUX_CI_SKIP_XCODE_SELECT=1 ./scripts/select-ci-xcode.sh >/dev/null
    DEVELOPER_DIR="$(sed -n 's/^DEVELOPER_DIR=//p' "$work/xcode.env" | tail -n 1)"
    [[ -n "$DEVELOPER_DIR" ]] || { echo "swift-test-bench.sh: no Xcode selected" >&2; exit 3; }
    export DEVELOPER_DIR
  fi

  # --- The measured tree --------------------------------------------------
  trap back_to_step_ref EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  # --depth only in a shallow clone: in a worktree of a full warm checkout it
  # would make the shared repository shallow.
  local depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  for sha in "$source_sha" "$restore_sha"; do
    [[ -n "$sha" ]] || continue
    if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
      git fetch -q --no-tags ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$sha" ||
        { echo "swift-test-bench.sh: could not fetch $sha" >&2; exit 3; }
    fi
  done
  if [[ -n "$source_sha" ]]; then
    git checkout -q --detach "$source_sha"
  fi
  [[ -f "$package/Package.swift" ]] || { echo "swift-test-bench.sh: $package has no Package.swift at $(git rev-parse HEAD)" >&2; exit 2; }
  if [[ -n "$restore_sha" ]]; then
    for path in "${restore_paths[@]}"; do
      [[ "$(git cat-file -t "$restore_sha:$path" 2>/dev/null)" == blob ]] ||
        { echo "swift-test-bench.sh: $path is not a file at $restore_sha" >&2; exit 2; }
    done
    git checkout -q "$restore_sha" -- "${restore_paths[@]}"
  fi

  note "# swift-test-bench"
  note ""
  note "- measured tree: $(git rev-parse HEAD) (step commit $step_ref)"
  note "- package: $package"
  note "- filter: $filter"
  note "- configuration: ${config:-debug}${config_args[*]:+ (${config_args[*]})}${bench_switch:+, $bench_switch=1}"
  if [[ -n "$restore_sha" ]]; then
    note "- restored from $restore_sha: ${restore_paths[*]}"
    git diff --stat HEAD -- "${restore_paths[@]}" | tee -a "$report"
  fi
  note "- host: $(hostname -s), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, macOS $(sw_vers -productVersion)"
  note "- Xcode: $(xcodebuild -version | tr '\n' ' ')"

  # --- Build ---------------------------------------------------------------
  # CmuxMobileKit names a local xcframework (a Package.swift binaryTarget) that
  # SwiftPM needs on disk even for a macOS build; it is built, not checked in.
  local t0=$SECONDS
  # Build output goes to the step log as it comes: a measurement that prints
  # nothing for 45 min is stopped as hung (the fleet's measure silence limit),
  # and a real hang then shows where it stopped.
  if [[ "$package" == cmux-next-ios/CmuxMobileKit ]]; then
    local ffi_status
    set +e
    JOBS="$(sysctl -n hw.ncpu)" bash cmux-next-ios/rust/scripts/build-xcframework.sh 2>&1 | tee "$work/ffi.log"
    local -a ffi_pipe=("${PIPESTATUS[@]}")
    set -e
    ffi_status=${ffi_pipe[0]}
    [[ ${ffi_pipe[1]} -eq 0 ]] || { echo "swift-test-bench.sh: could not write $work/ffi.log" >&2; exit 3; }
    [[ $ffi_status -eq 0 ]] || { echo "swift-test-bench.sh: CmuxMobileLinkFFI.xcframework build failed (exit $ffi_status)" >&2; exit 1; }
    # The script regenerates checked-in bindings; any difference is the tree's, not the run's.
    git diff --stat -- cmux-next-ios/ | tee -a "$report"
    note "- CmuxMobileLinkFFI.xcframework: built in $((SECONDS - t0)) s"
  fi
  t0=$SECONDS
  local build_status
  set +e
  swift build --package-path "$package" --build-tests ${config_args[@]+"${config_args[@]}"} 2>&1 | tee "$work/build.log"
  local -a build_pipe=("${PIPESTATUS[@]}")
  set -e
  build_status=${build_pipe[0]}
  [[ ${build_pipe[1]} -eq 0 ]] || { echo "swift-test-bench.sh: could not write $work/build.log" >&2; exit 3; }
  if [[ $build_status -ne 0 ]]; then
    grep -E "error:" "$work/build.log" | sort -u | head -40 || true
    note "- build: failed (exit $build_status) after $((SECONDS - t0)) s"
    exit 1
  fi
  note "- build: $((SECONDS - t0)) s"

  # --- Measure -------------------------------------------------------------
  note ""
  note "## swift test --filter $filter"
  t0=$SECONDS
  local status
  set +e
  if [[ -n "$bench_switch" ]]; then export "$bench_switch=1"; fi
  swift test --package-path "$package" --skip-build --filter "$filter" ${config_args[@]+"${config_args[@]}"} 2>&1 | tee "$work/test.log" | tee -a "$report"
  status=${PIPESTATUS[0]}
  set -e
  note ""
  # Swift Testing ends with "Test run with N test(s) ..."; XCTest prints
  # "Executed N test(s)" per suite and then for all of them, so its largest
  # count is the total. Zero in all: the filter matched nothing.
  local ran swt xct
  swt="$(grep -Eo 'Test run with [0-9]+ tests?' "$work/test.log" | grep -Eo '[0-9]+' | sort -n | tail -1 || true)"
  xct="$(grep -Eo 'Executed [0-9]+ tests?' "$work/test.log" | grep -Eo '[0-9]+' | sort -n | tail -1 || true)"
  ran=$(( ${swt:-0} + ${xct:-0} ))
  note "- swift test: exit $status, $ran test(s), $((SECONDS - t0)) s"
  if [[ "$ran" -eq 0 ]]; then
    note "- no test matched $filter"
    exit 1
  fi
  exit "$status"
}

note() { printf '%s\n' "$*" | tee -a "$report"; }

# Put the checkout back at the step's own commit (source= and restore= changed it).
back_to_step_ref() {
  [[ -n "${step_ref:-}" ]] || return 0
  git checkout -q -f --detach "$step_ref" >/dev/null 2>&1 || true
}

report=/dev/null
step_ref=""
main "$@"; exit $?
