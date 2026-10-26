#!/usr/bin/env bash
# Which Swift PGO and order-file paths work on the pinned Xcode (task 048): plans/cmux-next/startup-DESIGN.md section 9.
# The path_* functions run by name ("path_${path//-/_}").
# shellcheck disable=SC2317
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=../lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fleet-only.sh"
cmux_next_require_fleet probe-toolchain.sh "swiftc, clang and xcodebuild" "none (a manual fleet step, task 048)" \
  "cmux-ci run --class isolated --script scripts/cmux-next/pgo/probe-toolchain.sh --ref SHA"

all_paths="generate flush merge use use-weights trace-pc-guard scope-swiftpm scope-xcodebuild cmdline-scoped"
usage() {
  echo "usage: probe-toolchain.sh [--keep] [$(echo "$all_paths" | tr ' ' '|')]..." >&2
  echo "  named paths: exit 0 when all work; none: all run, exit 0 when the plan holds; --keep keeps the scratch dir" >&2
  exit 2
}
keep=0
paths=()
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    -h|--help) usage ;;
    *) case " $all_paths " in *" $arg "*) paths+=("$arg") ;; *) echo "probe-toolchain: unknown path '$arg'" >&2; usage ;; esac ;;
  esac
done
judge_plan=0
(( ${#paths[@]} )) || { read -r -a paths <<<"$all_paths"; judge_plan=1; }
unset CMUX_PGO_PROFDATA # only xcodebuild_root and scope-swiftpm set it, per build

[[ "$(uname -s)" == Darwin ]] || { echo "probe-toolchain: needs macOS (xcrun, xcodebuild, atos)" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then # the check-release-compile.sh selection
  xcode_app="${CMUX_PGO_PROBE_XCODE:-/Applications/Xcode_$(awk '$1 == "26" { print $2 }' "$here/../../ci/xcode-pins.txt").app}"
  [[ -d "$xcode_app" ]] || { echo "probe-toolchain: $xcode_app is not installed; set CMUX_PGO_PROBE_XCODE or DEVELOPER_DIR" >&2; exit 2; }
  export DEVELOPER_DIR="$xcode_app/Contents/Developer"
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-pgo-probe.XXXXXX")"
if (( keep )); then echo "probe-toolchain: scratch directory $work"; else trap 'rm -rf -- "$work"' EXIT; fi
cp -R "$here/probe-fixtures/." "$work/"
src="$work/src"
arch="$(uname -m)"
echo "probe-toolchain: $(xcodebuild -version | tr '\n' ' ')"
echo "probe-toolchain: $(xcrun swiftc --version 2>&1 | head -n 1)"
echo "probe-toolchain: $(xcrun llvm-profdata --version 2>&1 | grep -m 1 -i version || true)"
echo "probe-toolchain: macOS $(sw_vers -productVersion) $arch"

log=/dev/null
note() { echo "  $*" | tee -a "$log"; }
fail() { note "FAIL: $*"; return 1; }
run() { echo "+ $*" >>"$log"; "$@" >>"$log" 2>&1; }
swiftc_probe() { run xcrun swiftc -O -module-name probe "$@"; }
function_count() { # profile, function name part: its "Function count"
  xcrun llvm-profdata show --function="$2" "$1" 2>>"$log" | awk '/Function count:/ { print $3; exit }'
}

# 0 when a compile line in log $1 for module $2 has -profile-use=$3 (any file when $3 is empty), 1 when
# none does, 2 when the module was not compiled.
module_has_profile_use() {
  local lines
  lines="$(grep -E -- "-module-name $2( |$)" "$1" || true)"
  [[ -n "$lines" ]] || return 2
  grep -qF -- "-profile-use=${3:-}" <<<"$lines"
}
expect_scope() { # log, want (a profdata path; no: compiled without; never: without or not compiled), module...
  local log_file=$1 want=$2 rc=0 module status
  shift 2
  for module in "$@"; do
    status=0
    case "$want" in no|never) module_has_profile_use "$log_file" "$module" || status=$? ;;
      *) module_has_profile_use "$log_file" "$module" "$want" || status=$? ;; esac
    case "$status:$want" in
      1:no|1:never|2:never) note "$module: no -profile-use in $(basename "$log_file"), as wanted" ;;
      0:no|0:never) fail "$module got -profile-use in $(basename "$log_file")"; rc=1 ;;
      0:*) note "$module: -profile-use=$(basename "$want") in $(basename "$log_file"), as wanted" ;;
      2:*) fail "$module was not compiled in $(basename "$log_file"): it kept old objects"; rc=1 ;;
      *) fail "$module did not get -profile-use=$(basename "$want") in $(basename "$log_file")"; rc=1 ;;
    esac
  done
  return "$rc"
}

# The Release app's invocation (check-release-compile.sh --bench-hooks): OTHER_SWIFT_FLAGS on the command
# line, so the probe sees whether the package's unsafeFlags survive it.
xcodebuild_root() { # derived data, log, profdata for CMUX_PGO_PROFDATA (empty: unset), extra Swift flags
  (if [[ -n "$3" ]]; then export CMUX_PGO_PROFDATA="$3"; fi
    cd "$work/scope/Root" && xcodebuild -scheme RootApp -configuration Release -destination 'generic/platform=macOS' \
      -derivedDataPath "$1" ARCHS="$arch" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
      OTHER_SWIFT_FLAGS="\$(inherited) -DCMUX_BENCH_HOOKS${4:+ $4}" build) >"$2" 2>&1 \
    || fail "xcodebuild failed (see $2)"
}

generate_profile() { # plain -profile-generate, written at exit
  [[ -s "$work/generate/default.profraw" ]] && return 0
  mkdir -p "$work/generate"
  swiftc_probe -profile-generate "$src/main.swift" -o "$work/generate/probe" || return 1
  LLVM_PROFILE_FILE="$work/generate/default.profraw" run "$work/generate/probe" || return 1
  [[ -s "$work/generate/default.profraw" ]] || fail "no profraw written at exit"
}
flush_profiles() { # launch.profraw and rest.profraw from one run, through the runtime's flush API
  [[ -s "$work/flush/launch.profraw" && -s "$work/flush/rest.profraw" ]] && return 0
  mkdir -p "$work/flush"
  swiftc_probe -profile-generate -D CMUX_PGO_PROBE_FLUSH -import-objc-header "$src/profile_runtime.h" \
    "$src/main.swift" -o "$work/flush/probe" || return 1
  LLVM_PROFILE_FILE="$work/flush/exit.profraw" run "$work/flush/probe" "$work/flush/launch.profraw" "$work/flush/rest.profraw"
}
merge_profiles() {
  flush_profiles && run xcrun llvm-profdata merge -o "$work/flush/merged.profdata" "$work/flush/launch.profraw" "$work/flush/rest.profraw"
}
profdata=""
need_profdata() { # the merged flush profile, else the plain one: use and scope do not depend on the flush API
  [[ -n "$profdata" ]] && return 0
  if merge_profiles; then
    profdata="$work/flush/merged.profdata"
  elif generate_profile && run xcrun llvm-profdata merge -o "$work/generate/default.profdata" "$work/generate/default.profraw"; then
    profdata="$work/generate/default.profdata"
    note "the flush profile failed; using the plain -profile-generate profile"
  else
    fail "no profile: generate and flush both failed"
  fi
}
profile_marks() { # IR file: launchOnly's function_entry_count and every branch_weights tuple
  local md
  md="$(grep -m 1 -E '^define .*launchOnly.* !prof ![0-9]+' "$1" | grep -oE '!prof ![0-9]+' | cut -d' ' -f2 || true)"
  [[ -z "$md" ]] || grep -E "^$md = " "$1" | grep -F function_entry_count || true
  grep -oE '!"branch_weights"[^}]*' "$1" | sort -u || true
}

path_generate() {
  generate_profile || return 1
  note "command: swiftc -O -profile-generate main.swift; LLVM_PROFILE_FILE=default.profraw ./probe"
}
path_flush() {
  flush_profiles || return 1
  local ll rl lr rr
  ll="$(function_count "$work/flush/launch.profraw" launchOnly)"; rl="$(function_count "$work/flush/launch.profraw" restOnly)"
  lr="$(function_count "$work/flush/rest.profraw" launchOnly)"; rr="$(function_count "$work/flush/rest.profraw" restOnly)"
  note "launchOnly: launch=${ll:-?} rest=${lr:-?}; restOnly: launch=${rl:-?} rest=${rr:-?}"
  [[ "${ll:-0}" -gt 0 && "${rr:-0}" -gt 0 ]] || fail "a function ran but has no count" || return 1
  [[ "${rl:-0}" == 0 ]] || fail "restOnly is in launch.profraw" || return 1
  [[ "${lr:-0}" == 0 ]] || fail "launchOnly is in rest.profraw: reset_counters did not reset" || return 1
  note "command: set_filename(launch); write_file(); reset_counters(); ...; set_filename(rest); write_file()"
}
path_merge() {
  merge_profiles || fail "llvm-profdata merge failed" || return 1
  local launch rest
  launch="$(function_count "$work/flush/merged.profdata" launchOnly)"; rest="$(function_count "$work/flush/merged.profdata" restOnly)"
  note "merged: launchOnly=${launch:-?} restOnly=${rest:-?}"
  [[ "${launch:-0}" -gt 0 && "${rest:-0}" -gt 0 ]] || fail "a function lost its count in the merge" || return 1
  note "command: xcrun llvm-profdata merge -o cmux-next.profdata launch.profraw rest.profraw"
}
path_use() {
  need_profdata || return 1
  mkdir -p "$work/use"
  swiftc_probe -profile-use="$profdata" "$src/main.swift" -o "$work/use/probe" || fail "compile with -profile-use failed" || return 1
  run "$work/use/probe" || fail "the -profile-use binary did not run" || return 1
  note "command: swiftc -O -profile-use=cmux-next.profdata main.swift"
}
path_use_weights() { # the same compile with and without the profile; only the profile can change the IR
  need_profdata || return 1
  mkdir -p "$work/use"
  swiftc_probe -emit-ir "$src/main.swift" -o "$work/use/base.ll" || return 1
  swiftc_probe -profile-use="$profdata" -emit-ir "$src/main.swift" -o "$work/use/pgo.ll" || return 1
  local base pgo
  base="$(profile_marks "$work/use/base.ll")"; pgo="$(profile_marks "$work/use/pgo.ll")"
  note "launchOnly entry count: $(grep -c function_entry_count <<<"$pgo" || true) with the profile, $(grep -c function_entry_count <<<"$base" || true) without"
  note "branch_weights tuples: $(grep -c branch_weights <<<"$pgo" || true) with the profile, $(grep -c branch_weights <<<"$base" || true) without"
  [[ "$pgo" != "$base" ]] || fail "-profile-use left the profile metadata unchanged: the flag is ignored"
}
path_trace_pc_guard() {
  mkdir -p "$work/trace"
  run xcrun clang -O2 -c "$src/trace_hook.c" -o "$work/trace/trace_hook.o" || fail "clang trace_hook.c failed" || return 1
  local san built=""
  for san in undefined address; do
    swiftc_probe -sanitize="$san" -sanitize-coverage=func,trace-pc-guard "$src/main.swift" "$work/trace/trace_hook.o" \
      -o "$work/trace/probe" && { built="$san"; break; }
    note "-sanitize=$san with -sanitize-coverage did not build"
  done
  [[ -n "$built" ]] || fail "no sanitizer builds with -sanitize-coverage" || return 1
  CMUX_PGO_TRACE_FILE="$work/trace/pcs.txt" run "$work/trace/probe" || fail "instrumented probe did not run" || return 1
  [[ -s "$work/trace/pcs.txt" ]] || fail "the guard callback recorded nothing" || return 1
  xargs xcrun atos -o "$work/trace/probe" <"$work/trace/pcs.txt" >"$work/trace/symbols.txt" 2>>"$log" || fail "atos failed" || return 1
  local launch_line rest_line
  launch_line="$(grep -n -m 1 'launchOnly' "$work/trace/symbols.txt" | cut -d: -f1 || true)"
  rest_line="$(grep -n -m 1 'restOnly' "$work/trace/symbols.txt" | cut -d: -f1 || true)"
  note "first-hit order: launchOnly at ${launch_line:-?}, restOnly at ${rest_line:-?}"
  [[ -n "$launch_line" && -n "$rest_line" && "$launch_line" -lt "$rest_line" ]] || fail "symbols missing or out of order" || return 1
  note "command: swiftc -O -sanitize=$built -sanitize-coverage=func,trace-pc-guard main.swift trace_hook.o; atos -o probe"
}
path_scope_swiftpm() {
  need_profdata || return 1
  local log_file="$work/scope/swiftpm.log" rc=0
  CMUX_PGO_PROFDATA="$profdata" xcrun swift build -c release -v --package-path "$work/scope/Root" \
    --scratch-path "$work/scope/spm" >"$log_file" 2>&1 || fail "swift build failed (see $log_file)" || return 1
  expect_scope "$log_file" "$profdata" RootApp Mid || rc=1
  expect_scope "$log_file" no Dep || rc=1
  return "$rc"
}
path_scope_xcodebuild() { # one kept DerivedData, as CI keeps one: on, off, on, on with a profile at a new path
  need_profdata || return 1
  local dd="$work/scope/dd" moved="$work/scope/moved.profdata" step=0 profile log_file rc=0
  cp "$profdata" "$moved"
  for profile in "$profdata" "" "$profdata" "$moved"; do
    step=$((step + 1))
    log_file="$work/scope/xcodebuild-$step.log"
    xcodebuild_root "$dd" "$log_file" "$profile" || return 1
    expect_scope "$log_file" "${profile:-no}" RootApp Mid || rc=1
    expect_scope "$log_file" "$( ((step == 1)) && echo no || echo never)" Dep || rc=1
  done
  return "$rc"
}
path_cmdline_scoped() { # expected FAIL: the command line reaches every package
  need_profdata || return 1
  local log_file="$work/scope/xcodebuild-cmdline.log" rc=0
  xcodebuild_root "$work/scope/dd-cmdline" "$log_file" "" "-profile-use=$profdata" || return 1
  expect_scope "$log_file" "$profdata" RootApp || rc=1
  expect_scope "$log_file" no Dep || rc=1
  return "$rc"
}

passed=" "
for path in "${paths[@]}"; do
  log="$work/$path.log"
  : >"$log"
  echo "== $path"
  if "path_${path//-/_}"; then
    passed+="$path "
    echo "== $path: PASS"
  else
    echo "== $path: FAIL (last lines of $log)"
    tail -n 25 "$log" | sed 's/^/   | /'
  fi
done
ok() { [[ "$passed" == *" $1 "* ]]; }
printf '\n%-17s %s\n' path result
for path in "${paths[@]}"; do printf '%-17s %s\n' "$path" "$(ok "$path" && echo PASS || echo FAIL)"; done
if (( ! judge_plan )); then
  for path in "${paths[@]}"; do ok "$path" || exit 1; done
  exit 0
fi
plan=0
{ { ok flush && ok merge; } || ok trace-pc-guard; } || plan=1
for path in use use-weights scope-xcodebuild; do ok "$path" || plan=1; done
if (( plan == 0 )); then echo "probe-toolchain: F's plan holds on this Xcode"; exit 0; fi
echo "probe-toolchain: F's plan does not hold: it needs (flush and merge) or trace-pc-guard, use, use-weights, scope-xcodebuild"
exit 1
