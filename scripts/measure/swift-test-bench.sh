#!/usr/bin/env bash
# One swift-test benchmark, measured alone: a fleet measurement step (class
# exclusive, label measure: nothing else runs on the host while it measures)
# builds a Swift package's tests once, then runs the one filter it names. The
# test's own output (its print lines, e.g. a benchmark's numbers) is in the step
# log and in the artifact.
#
#   cmux-ci run --class exclusive --script scripts/measure/swift-test-bench.sh --ref SHA \
#     --arg PACKAGE --arg FILTER [--arg source=SHA] [--arg restore_from=SHA --arg restore=PATH,PATH] \
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
#
# The step fails when the build fails, when the filter runs no test, or when a
# test fails; it never retries. The checkout goes back to the step's own commit
# when the script ends.
set -euo pipefail

# The whole script is one function, read before it runs: source= replaces the
# checkout's files, this one included.
main() {
  # shellcheck source-path=SCRIPTDIR source=../cmux-next/lib/fleet-only.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/lib/fleet-only.sh"

  # --- Arguments (checked before anything else runs) ----------------------
  local usage="usage: swift-test-bench.sh PACKAGE FILTER [source=SHA] [restore_from=SHA restore=PATH[,PATH...]]"
  [[ $# -ge 2 ]] || { echo "$usage" >&2; exit 2; }
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
  local source_sha="" restore_sha="" restore_list="" arg
  for arg in "$@"; do
    case "$arg" in
      source=*) [[ -z "$source_sha" ]] || { echo "$usage" >&2; exit 2; }; source_sha=${arg#source=} ;;
      restore_from=*) [[ -z "$restore_sha" ]] || { echo "$usage" >&2; exit 2; }; restore_sha=${arg#restore_from=} ;;
      restore=*) [[ -z "$restore_list" ]] || { echo "$usage" >&2; exit 2; }; restore_list=${arg#restore=} ;;
      *) echo "swift-test-bench.sh: unknown argument '$arg'; $usage" >&2; exit 2 ;;
    esac
  done
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
  if [[ "$package" == cmux-next-ios/CmuxMobileKit ]]; then
    JOBS="$(sysctl -n hw.ncpu)" bash cmux-next-ios/rust/scripts/build-xcframework.sh >"$work/ffi.log" 2>&1 ||
      { tail -60 "$work/ffi.log"; echo "swift-test-bench.sh: CmuxMobileLinkFFI.xcframework build failed" >&2; exit 1; }
    # The script regenerates checked-in bindings; any difference is the tree's, not the run's.
    git diff --stat -- cmux-next-ios/ | tee -a "$report"
    note "- CmuxMobileLinkFFI.xcframework: built in $((SECONDS - t0)) s"
  fi
  t0=$SECONDS
  if ! swift build --package-path "$package" --build-tests >"$work/build.log" 2>&1; then
    grep -E "error:" "$work/build.log" | sort -u | head -40 || true
    tail -40 "$work/build.log"
    note "- build: failed after $((SECONDS - t0)) s"
    exit 1
  fi
  note "- build: $((SECONDS - t0)) s"

  # --- Measure -------------------------------------------------------------
  note ""
  note "## swift test --filter $filter"
  t0=$SECONDS
  local status
  set +e
  swift test --package-path "$package" --skip-build --filter "$filter" 2>&1 | tee "$work/test.log" | tee -a "$report"
  status=${PIPESTATUS[0]}
  set -e
  note ""
  # Swift Testing ends with "Test run with N test(s) ..."; XCTest with
  # "Executed N test(s)". Neither, or zero tests in all: the filter matched nothing.
  local ran
  ran="$(grep -Eo 'Test run with [0-9]+ tests?|Executed [0-9]+ tests?' "$work/test.log" | grep -Eo '[0-9]+' | awk '{ s += $1 } END { print s + 0 }')"
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
