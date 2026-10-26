#!/usr/bin/env bash
# Spike for p08-startup task 048 (plans/cmux-next/chrome-parity/p08-startup.md, section F): which Swift
# PGO and order-file paths work on the pinned Xcode. Each path builds a small fixture in a scratch
# directory and checks one thing. Results and the commands that work: plans/cmux-next/startup-DESIGN.md,
# section 9.
#
#   generate          swiftc -profile-generate writes a non-empty profraw at exit (LLVM_PROFILE_FILE)
#   flush             __llvm_profile_set_filename + __llvm_profile_write_file + __llvm_profile_reset_counters
#                     split one run into launch.profraw and rest.profraw: a launch-only function has
#                     counts only in launch, a rest-only function only in rest
#   merge             xcrun llvm-profdata merge of both files keeps both functions' counts
#   use               swiftc -profile-use=<merged.profdata> compiles, links and runs
#   use-weights       the -profile-use IR carries branch_weights (the flag is not silently ignored)
#   trace-pc-guard    fallback: -sanitize-coverage=func,trace-pc-guard (with -sanitize=undefined, else
#                     address) and a C callback record first-hit PCs; atos names launch before rest
#   scope-swiftpm     Package.swift unsafeFlags from Context.environment["CMUX_PGO_PROFDATA"], under
#                     .when(configuration: .release): `swift build -c release` passes -profile-use to
#                     the targets that ask (root, local path package) and not to the one that does not
#   scope-xcodebuild  the same manifest through `xcodebuild -configuration Release` (the Release app's
#                     build), and with the variable unset a fresh build has no -profile-use anywhere
#   cmdline-scoped    OTHER_SWIFT_FLAGS=-profile-use=... on the xcodebuild command line stays out of the
#                     package that did not ask (expected to fail: the command line reaches every target)
#
# Usage: probe-toolchain.sh [--keep] [path...]
#   Named paths: exit 0 when every one works, 1 when one does not. No path: all run, and the exit is 0
#   only when F's plan holds: (flush and merge) or trace-pc-guard, and use, and scope-xcodebuild.
#   A table of PASS/FAIL per path prints either way. Exit 2: usage, not macOS, or no Xcode.
#   --keep leaves the scratch directory (fixtures, logs, profiles) and prints its path.
# Xcode: DEVELOPER_DIR when set, else CMUX_PGO_PROBE_XCODE (an .app path), else the nightly's
# /Applications/Xcode_<version>.app from the "26" line of scripts/ci/xcode-pins.txt, as
# check-release-compile.sh does.
# The path_* functions run by name ("path_${path//-/_}").
# shellcheck disable=SC2317
set -euo pipefail

# swiftc, clang and xcodebuild build fixtures: fleet or GitHub runner only.
# shellcheck source-path=SCRIPTDIR source=../lib/fleet-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/fleet-only.sh"
cmux_next_require_fleet probe-toolchain.sh "swiftc, clang and xcodebuild" "none (a manual fleet step, task 048)" \
  "cmux-ci run --class isolated --script scripts/cmux-next/pgo/probe-toolchain.sh --ref SHA"

all_paths="generate flush merge use use-weights trace-pc-guard scope-swiftpm scope-xcodebuild cmdline-scoped"
usage() { echo "usage: probe-toolchain.sh [--keep] [$(echo "$all_paths" | tr ' ' '|')]..." >&2; exit 2; }

keep=0
paths=()
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    -h|--help) usage ;;
    *)
      case " $all_paths " in *" $arg "*) paths+=("$arg") ;; *) echo "probe-toolchain: unknown path '$arg'" >&2; usage ;; esac
      ;;
  esac
done
judge_plan=0
if (( ${#paths[@]} == 0 )); then
  read -r -a paths <<<"$all_paths"
  judge_plan=1
fi
# Only the scope paths set it, per build.
unset CMUX_PGO_PROFDATA

[[ "$(uname -s)" == Darwin ]] || { echo "probe-toolchain: needs macOS (xcrun, xcodebuild, atos)" >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  xcode_app="${CMUX_PGO_PROBE_XCODE:-}"
  if [[ -z "$xcode_app" ]]; then
    pinned="$(awk '$1 == "26" { print $2 }' "$repo_root/scripts/ci/xcode-pins.txt")"
    xcode_app="/Applications/Xcode_${pinned}.app"
  fi
  [[ -d "$xcode_app" ]] || { echo "probe-toolchain: $xcode_app is not installed; set CMUX_PGO_PROBE_XCODE or DEVELOPER_DIR" >&2; exit 2; }
  export DEVELOPER_DIR="$xcode_app/Contents/Developer"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-pgo-probe.XXXXXX")"
if (( keep )); then
  echo "probe-toolchain: scratch directory $work"
else
  trap 'rm -rf -- "$work"' EXIT
fi
arch="$(uname -m)"

echo "probe-toolchain: $(xcodebuild -version | tr '\n' ' ')"
echo "probe-toolchain: $(xcrun swiftc --version 2>&1 | head -n 1)"
echo "probe-toolchain: $(xcrun llvm-profdata --version 2>&1 | grep -m 1 -i version || true)"
echo "probe-toolchain: macOS $(sw_vers -productVersion) $arch"

# --- fixtures -----------------------------------------------------------------------------------

mkdir -p "$work/src"
cat >"$work/src/profile_runtime.h" <<'EOF'
// The compiler-rt profile runtime entry points that -profile-generate links in.
int __llvm_profile_write_file(void);
void __llvm_profile_reset_counters(void);
void __llvm_profile_set_filename(const char *name);
EOF
cat >"$work/src/main.swift" <<'EOF'
// Probe program: launchOnly runs before the flush, restOnly after it.
@inline(never) func launchOnly(_ n: Int) -> Int {
    var sum = 0
    for i in 0..<n {
        if i % 7 == 0 { sum &+= i } else { sum &-= 1 }
    }
    return sum
}

@inline(never) func restOnly(_ n: Int) -> Int {
    var sum = 1
    for i in 0..<n where i % 3 == 0 { sum = sum &* 31 &+ i }
    return sum
}

var sink = launchOnly(1000)
#if CMUX_PGO_PROBE_FLUSH
// launch.profraw at the startup mark, then counters start again; rest.profraw before quit.
let files = CommandLine.arguments.dropFirst()
precondition(files.count == 2, "usage: probe LAUNCH.profraw REST.profraw")
files.first!.withCString { __llvm_profile_set_filename($0) }
precondition(__llvm_profile_write_file() == 0, "launch write failed")
__llvm_profile_reset_counters()
sink &+= restOnly(1000)
files.last!.withCString { __llvm_profile_set_filename($0) }
precondition(__llvm_profile_write_file() == 0, "rest write failed")
#else
sink &+= restOnly(1000)
#endif
print(sink)
EOF
cat >"$work/src/trace_hook.c" <<'EOF'
// First-hit function PCs for an order file (the trace-pc-guard fallback). Not instrumented itself.
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static FILE *trace_out;

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
  static uint32_t next;
  if (start == stop || *start) return;
  for (uint32_t *guard = start; guard < stop; guard++) *guard = ++next;
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
  if (!*guard) return;
  *guard = 0;
  if (!trace_out) {
    const char *path = getenv("CMUX_PGO_TRACE_FILE");
    trace_out = fopen(path ? path : "/dev/null", "w");
    if (!trace_out) return;
  }
  uintptr_t pc = (uintptr_t)__builtin_return_address(0) - (uintptr_t)_dyld_get_image_vmaddr_slide(0);
  fprintf(trace_out, "0x%lx\n", (unsigned long)pc);
  fflush(trace_out);
}
EOF

# Scope fixture: Root (asks for the profile), Mid (a local path package that asks: CmuxNext as
# cmux.xcodeproj's local package reference), Dep (a package that does not ask: Sentry, Sparkle).
mkdir -p "$work/scope/Root/Sources/RootApp" "$work/scope/Mid/Sources/Mid" "$work/scope/Dep/Sources/Dep"
# Swift source, not shell: nothing in it expands.
# shellcheck disable=SC2016
pgo_manifest_settings='let profdata = Context.environment["CMUX_PGO_PROFDATA"]
let pgo: [SwiftSetting] = profdata.map { [.unsafeFlags(["-profile-use=\($0)"], .when(configuration: .release))] } ?? []'
cat >"$work/scope/Root/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
$pgo_manifest_settings
let package = Package(
    name: "Root",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../Mid"), .package(path: "../Dep")],
    targets: [
        .executableTarget(
            name: "RootApp",
            dependencies: [.product(name: "Mid", package: "Mid"), .product(name: "Dep", package: "Dep")],
            swiftSettings: pgo
        ),
    ]
)
EOF
cat >"$work/scope/Mid/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription
$pgo_manifest_settings
let package = Package(
    name: "Mid",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Mid", targets: ["Mid"])],
    targets: [.target(name: "Mid", swiftSettings: pgo)]
)
EOF
cat >"$work/scope/Dep/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Dep",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Dep", targets: ["Dep"])],
    targets: [.target(name: "Dep")]
)
EOF
echo 'public func mid(_ n: Int) -> Int { n % 2 == 0 ? n / 2 : 3 * n + 1 }' >"$work/scope/Mid/Sources/Mid/Mid.swift"
echo 'public func dep(_ n: Int) -> Int { n > 10 ? n - 10 : n + 10 }' >"$work/scope/Dep/Sources/Dep/Dep.swift"
printf 'import Dep\nimport Mid\nprint(mid(dep(7)))\n' >"$work/scope/Root/Sources/RootApp/main.swift"

# --- helpers ------------------------------------------------------------------------------------

log=/dev/null
note() { echo "  $*" | tee -a "$log"; }
fail() { note "FAIL: $*"; return 1; }
run() { echo "+ $*" >>"$log"; "$@" >>"$log" 2>&1; }

# The "Function count" of the first function whose name contains $2, in profile $1.
function_count() {
  xcrun llvm-profdata show --function="$2" "$1" 2>>"$log" \
    | awk '/Function count:/ { print $3; exit }'
}

# 0 when some compile line in $1 for module $2 carries -profile-use, 1 when none does, 2 when the
# module was not compiled at all.
module_has_profile_use() {
  local lines
  lines="$(grep -E -- "-module-name $2( |$)" "$1" || true)"
  [[ -n "$lines" ]] || return 2
  grep -q -- "-profile-use=" <<<"$lines"
}

expect_scope() { # log, module, want (yes|no)
  local status=0
  module_has_profile_use "$1" "$2" || status=$?
  case "$status:$3" in
    0:yes|1:no) note "$2: -profile-use $3, as wanted" ;;
    2:*) fail "$2 has no compile line in $(basename "$1")" ;;
    0:no) fail "$2 got -profile-use (it did not ask for it)" ;;
    *) fail "$2 did not get -profile-use" ;;
  esac
}

swiftc_probe() { run xcrun swiftc -O -module-name probe "$@"; }

xcodebuild_root() { # derived data, then extra build settings
  local derived=$1
  shift
  (cd "$work/scope/Root" && xcodebuild -scheme RootApp -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    ARCHS="$arch" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO "$@" build)
}

profdata="$work/flush/merged.profdata"
need_profdata() {
  [[ -s "$profdata" ]] || { merge_profiles >/dev/null 2>&1 || true; }
  [[ -s "$profdata" ]] || fail "no merged.profdata (the merge path failed)"
}

# --- paths --------------------------------------------------------------------------------------

path_generate() {
  mkdir -p "$work/generate"
  swiftc_probe -profile-generate "$work/src/main.swift" -o "$work/generate/probe" || return 1
  LLVM_PROFILE_FILE="$work/generate/default.profraw" run "$work/generate/probe" || return 1
  [[ -s "$work/generate/default.profraw" ]] || fail "no profraw written at exit" || return 1
  note "command: swiftc -O -profile-generate main.swift; LLVM_PROFILE_FILE=default.profraw ./probe"
}

flush_built=0
build_flush_probe() {
  (( flush_built )) && return 0
  mkdir -p "$work/flush"
  swiftc_probe -profile-generate -D CMUX_PGO_PROBE_FLUSH -import-objc-header "$work/src/profile_runtime.h" \
    "$work/src/main.swift" -o "$work/flush/probe" || return 1
  LLVM_PROFILE_FILE="$work/flush/exit.profraw" run "$work/flush/probe" "$work/flush/launch.profraw" "$work/flush/rest.profraw" \
    || return 1
  flush_built=1
}

path_flush() {
  build_flush_probe || return 1
  local f
  for f in launch rest; do
    [[ -s "$work/flush/$f.profraw" ]] || fail "$f.profraw is empty or missing" || return 1
  done
  local launch_in_launch rest_in_launch launch_in_rest rest_in_rest
  launch_in_launch="$(function_count "$work/flush/launch.profraw" launchOnly)"
  rest_in_launch="$(function_count "$work/flush/launch.profraw" restOnly)"
  launch_in_rest="$(function_count "$work/flush/rest.profraw" launchOnly)"
  rest_in_rest="$(function_count "$work/flush/rest.profraw" restOnly)"
  note "launchOnly: launch=${launch_in_launch:-?} rest=${launch_in_rest:-?}; restOnly: launch=${rest_in_launch:-?} rest=${rest_in_rest:-?}"
  [[ "${launch_in_launch:-0}" -gt 0 && "${rest_in_rest:-0}" -gt 0 ]] || fail "a function ran but has no count" || return 1
  [[ "${rest_in_launch:-0}" == 0 ]] || fail "restOnly is in launch.profraw" || return 1
  [[ "${launch_in_rest:-0}" == 0 ]] || fail "launchOnly is in rest.profraw: reset_counters did not reset" || return 1
  note "command: set_filename(launch); write_file(); reset_counters(); ...; set_filename(rest); write_file()"
}

merge_profiles() {
  build_flush_probe || return 1
  run xcrun llvm-profdata merge -o "$profdata" "$work/flush/launch.profraw" "$work/flush/rest.profraw"
}

path_merge() {
  merge_profiles || fail "llvm-profdata merge failed" || return 1
  local launch rest
  launch="$(function_count "$profdata" launchOnly)"
  rest="$(function_count "$profdata" restOnly)"
  note "merged: launchOnly=${launch:-?} restOnly=${rest:-?}"
  [[ "${launch:-0}" -gt 0 && "${rest:-0}" -gt 0 ]] || fail "a function lost its count in the merge" || return 1
  note "command: xcrun llvm-profdata merge -o cmux-next.profdata launch.profraw rest.profraw"
}

path_use() {
  need_profdata || return 1
  mkdir -p "$work/use"
  swiftc_probe -profile-use="$profdata" "$work/src/main.swift" -o "$work/use/probe" || fail "compile with -profile-use failed" || return 1
  run "$work/use/probe" || fail "the -profile-use binary did not run" || return 1
  note "command: swiftc -O -profile-use=cmux-next.profdata main.swift"
}

path_use_weights() {
  need_profdata || return 1
  mkdir -p "$work/use"
  swiftc_probe -profile-use="$profdata" -emit-ir "$work/src/main.swift" -o "$work/use/probe.ll" || return 1
  local weights
  weights="$(grep -c 'branch_weights' "$work/use/probe.ll" || true)"
  note "branch_weights in the IR: $weights"
  [[ "$weights" -gt 0 ]] || fail "-profile-use left no branch weights"
}

path_trace_pc_guard() {
  mkdir -p "$work/trace"
  run xcrun clang -O2 -c "$work/src/trace_hook.c" -o "$work/trace/trace_hook.o" || fail "clang trace_hook.c failed" || return 1
  local sanitizer built=""
  for sanitizer in undefined address; do
    if swiftc_probe -sanitize="$sanitizer" -sanitize-coverage=func,trace-pc-guard \
      "$work/src/main.swift" "$work/trace/trace_hook.o" -o "$work/trace/probe-$sanitizer"; then
      built="$sanitizer"
      break
    fi
    note "-sanitize=$sanitizer with -sanitize-coverage did not build"
  done
  [[ -n "$built" ]] || fail "no sanitizer builds with -sanitize-coverage" || return 1
  CMUX_PGO_TRACE_FILE="$work/trace/pcs.txt" run "$work/trace/probe-$built" || fail "instrumented probe did not run" || return 1
  [[ -s "$work/trace/pcs.txt" ]] || fail "the guard callback recorded nothing" || return 1
  xargs xcrun atos -o "$work/trace/probe-$built" <"$work/trace/pcs.txt" >"$work/trace/symbols.txt" 2>>"$log" \
    || fail "atos failed" || return 1
  local launch_line rest_line
  launch_line="$(grep -n -m 1 'launchOnly' "$work/trace/symbols.txt" | cut -d: -f1 || true)"
  rest_line="$(grep -n -m 1 'restOnly' "$work/trace/symbols.txt" | cut -d: -f1 || true)"
  note "first-hit order: launchOnly at ${launch_line:-?}, restOnly at ${rest_line:-?} of $(wc -l <"$work/trace/symbols.txt" | tr -d ' ')"
  [[ -n "$launch_line" && -n "$rest_line" && "$launch_line" -lt "$rest_line" ]] || fail "symbols missing or out of order" || return 1
  note "command: swiftc -O -sanitize=$built -sanitize-coverage=func,trace-pc-guard main.swift trace_hook.o; atos -o probe"
}

path_scope_swiftpm() {
  need_profdata || return 1
  local scope_log="$work/scope/swiftpm-on.log"
  CMUX_PGO_PROFDATA="$profdata" xcrun swift build -c release -v --package-path "$work/scope/Root" \
    --scratch-path "$work/scope/spm" >"$scope_log" 2>&1 || fail "swift build failed (see $scope_log)" || return 1
  local status=0
  expect_scope "$scope_log" RootApp yes || status=1
  expect_scope "$scope_log" Mid yes || status=1
  expect_scope "$scope_log" Dep no || status=1
  return "$status"
}

path_scope_xcodebuild() {
  need_profdata || return 1
  local on="$work/scope/xcodebuild-on.log" off="$work/scope/xcodebuild-off.log" status=0
  CMUX_PGO_PROFDATA="$profdata" xcodebuild_root "$work/scope/dd-on" >"$on" 2>&1 \
    || fail "xcodebuild with CMUX_PGO_PROFDATA failed (see $on)" || return 1
  expect_scope "$on" RootApp yes || status=1
  expect_scope "$on" Mid yes || status=1
  expect_scope "$on" Dep no || status=1
  # Unset: a fresh build must not reuse a cached manifest that still has the flag.
  xcodebuild_root "$work/scope/dd-off" >"$off" 2>&1 || fail "xcodebuild without CMUX_PGO_PROFDATA failed (see $off)" || return 1
  expect_scope "$off" RootApp no || status=1
  expect_scope "$off" Mid no || status=1
  return "$status"
}

path_cmdline_scoped() {
  need_profdata || return 1
  local cmdline="$work/scope/xcodebuild-cmdline.log"
  # $(inherited) is an Xcode build-setting reference, not shell.
  # shellcheck disable=SC2016
  xcodebuild_root "$work/scope/dd-cmdline" 'OTHER_SWIFT_FLAGS=$(inherited) -profile-use='"$profdata" >"$cmdline" 2>&1 || fail "xcodebuild with OTHER_SWIFT_FLAGS failed (see $cmdline)" || return 1
  expect_scope "$cmdline" RootApp yes || return 1
  expect_scope "$cmdline" Dep no
}

# --- run ----------------------------------------------------------------------------------------

passed=" "
for path in "${paths[@]}"; do
  log="$work/$path.log"
  : >"$log"
  echo "== $path"
  status=0
  "path_${path//-/_}" || status=$?
  if (( status == 0 )); then
    passed+="$path "
    echo "== $path: PASS"
  else
    echo "== $path: FAIL (last lines of $log)"
    tail -n 25 "$log" | sed 's/^/   | /'
  fi
done

ok() { case "$passed" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
echo
echo "path              result"
for path in "${paths[@]}"; do
  printf '%-17s %s\n' "$path" "$(ok "$path" && echo PASS || echo FAIL)"
done

if (( ! judge_plan )); then
  for path in "${paths[@]}"; do ok "$path" || exit 1; done
  exit 0
fi
plan=0
{ { ok flush && ok merge; } || ok trace-pc-guard; } || plan=1
ok use || plan=1
ok scope-xcodebuild || plan=1
if (( plan == 0 )); then
  echo "probe-toolchain: F's plan holds on this Xcode"
else
  echo "probe-toolchain: F's plan does not hold: it needs (flush and merge) or trace-pc-guard, use, scope-xcodebuild"
fi
exit "$plan"
