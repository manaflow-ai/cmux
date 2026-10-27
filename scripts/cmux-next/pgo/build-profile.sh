#!/usr/bin/env bash
# build-profile.sh --tag TAG [--out DIR] [--skip-build] [--no-launch] [--timeout SECONDS] [-- RELOAD_ARGS...]
#
# Stage 0 of the cmux-next PGO pipeline (plans/cmux-next/chrome-parity/p08-startup.md, section F, task 049):
# builds the instrumented app (`scripts/reload.sh --config profile`: Release optimization, CMUX_BENCH_HOOKS,
# CMUX_PGO_PROFILE, Swift -profile-generate, -fprofile-instr-generate at link), then launches it once with
# LLVM_PROFILE_FILE set, quits it through debug.quit and checks that the app's own .profraw has counts.
# Chrome's equivalent is the chrome_pgo_phase=1 build that tools/pgo/generate_profile.py runs
# (docs/pgo.md). Stage 1 (run-scenarios.py --stage profile, task 050) drives the real scenarios.
#
# It runs only as a fleet step (lib/fleet-only.sh), never on a person's Mac:
#   cmux-ci run --class isolated --script "scripts/cmux-next/pgo/build-profile.sh --tag TAG" --ref SHA
#
# Exit codes: 0 ok, 1 the build or the profile check failed, 2 usage.
#
# Seams (tests only): CMUX_PGO_RELOAD replaces scripts/reload.sh, CMUX_PGO_LAUNCHER replaces the launch
# (called as `LAUNCHER APP OUT TIMEOUT` with LLVM_PROFILE_FILE exported; it prints `pid=N` for the app it
# launched and quit), CMUX_PGO_LLVM_PROFDATA replaces `xcrun llvm-profdata`.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/../../.." && pwd -P)"

# shellcheck source=SCRIPTDIR/../lib/fleet-only.sh
source "$script_dir/../lib/fleet-only.sh"
cmux_next_require_fleet pgo/build-profile.sh "xcodebuild (reload.sh --config profile) and an app launch" \
  "none, a cmux-ci fleet step" \
  'cmux-ci run --class isolated --script "scripts/cmux-next/pgo/build-profile.sh --tag TAG" --ref SHA'

usage() {
  sed -n '2,2p' "${BASH_SOURCE[0]}" | sed 's/^# /usage: /' >&2
  exit 2
}

tag=""
out=""
build=1
launch=1
timeout=180
reload_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) tag="${2:-}"; shift 2 || usage ;;
    --out) out="${2:-}"; shift 2 || usage ;;
    --skip-build) build=0; shift ;;
    --no-launch) launch=0; shift ;;
    --timeout) timeout="${2:-}"; shift 2 || usage ;;
    --) shift; reload_args=("$@"); break ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

# The tag must already be reload.sh's slug (lowercase words joined by '-') so the bundle path below is the one
# reload.sh stages: `cmux DEV <slug>.app` (reload.sh: APP_NAME, sanitize_path).
if [[ ! "$tag" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  echo "error: --tag takes a slug of lowercase letters, digits and '-' (got '${tag}')" >&2
  exit 2
fi
if [[ ! "$timeout" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --timeout takes a positive number of seconds (got '${timeout}')" >&2
  exit 2
fi
for arg in "${reload_args[@]+"${reload_args[@]}"}"; do
  case "$arg" in
    --tag|--tag=*|--config|--config=*|--release|--derived-data|--name|--launch|--build-only)
      echo "error: $arg is set by build-profile.sh; do not pass it after --" >&2
      exit 2 ;;
  esac
done

# The same DerivedData reload.sh resolves (resolve_tagged_derived_data), passed to it explicitly so both agree.
derived="${CMUX_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/cmux-${tag}}"
if [[ "$derived" != /* ]]; then
  echo "error: CMUX_DERIVED_DATA must be an absolute path, got '$derived'" >&2
  exit 2
fi
app="$derived/Build/Products/Release/cmux DEV ${tag}.app"
reload="${CMUX_PGO_RELOAD:-$root/scripts/reload.sh}"

# Not --build-only: that mode stamps only a staging copy and deletes it on exit. A tagged build without --launch
# stamps the Release product (cmux.app) and moves it to `cmux DEV <tag>.app` as a new directory, and starts
# nothing; --no-global-cli-links leaves /tmp/cmux-cli alone. The inode check refuses a bundle from an earlier build.
bundle_inode() {
  if [[ -d "$app" ]]; then python3 -I -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$app"; fi
}
if (( build )); then
  stale_inode="$(bundle_inode)"
  echo "==> build-profile: building the profile configuration of tag ${tag}"
  "$reload" --tag "$tag" --config profile --no-global-cli-links --derived-data "$derived" \
    "${reload_args[@]+"${reload_args[@]}"}"
  if [[ -n "$stale_inode" && "$(bundle_inode)" == "$stale_inode" ]]; then
    echo "error: $app is the bundle of an earlier build: reload.sh did not publish this one" >&2
    exit 1
  fi
fi

if [[ ! -d "$app" ]]; then
  echo "error: no profile build at $app" >&2
  exit 1
fi
read_plist() {
  python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get(sys.argv[2], ""))' \
    "$app/Contents/Info.plist" "$1"
}
config="$(read_plist CMUXBuildConfiguration)"
if [[ "$config" != profile ]]; then
  echo "error: $app was built with --config '${config}', not profile" >&2
  exit 1
fi
exe="$app/Contents/MacOS/$(read_plist CFBundleExecutable)"
if [[ ! -f "$exe" ]]; then
  echo "error: no main executable in $app" >&2
  exit 1
fi
# The counter section is named in the Mach-O load commands, so a stripped Release executable still shows it.
if ! LC_ALL=C grep -aq '__llvm_prf_cnts' "$exe"; then
  echo "error: $exe has no __llvm_prf_cnts section: -profile-generate did not reach the app" >&2
  exit 1
fi
echo "==> build-profile: $app is instrumented"

if (( ! launch )); then
  exit 0
fi

if [[ -z "$out" ]]; then
  out="$(mktemp -d "${TMPDIR:-/tmp}/cmux-pgo-${tag}.XXXXXX")"
fi
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
# %p keeps each process's file apart: helper processes built in the same scheme are instrumented too and
# inherit the variable; only the app's own file (its pid) is checked.
export LLVM_PROFILE_FILE="$out/cmux-next-%p.profraw"

default_launcher() {
  python3 -I - "$@" <<'PY'
import os
import sys

app, out, timeout = sys.argv[1], sys.argv[2], float(sys.argv[3])
sys.path.insert(0, os.path.join(os.environ["CMUX_PGO_ROOT"], "scripts", "cmux-next"))
from bench_launch import BenchApp  # noqa: E402

bench = BenchApp(app, out=out, env={"LLVM_PROFILE_FILE": os.environ["LLVM_PROFILE_FILE"]})
try:
    bench.launch(timeout=timeout)
finally:
    # debug.quit ends the app through NSApplication terminate (QuitCoordinator), so exit() runs the profile
    # runtime's atexit writer. stop()'s last fallback, KILL, writes nothing, and the check below says so.
    bench.stop()
    if bench.process is not None:
        print(f"pid={bench.process.pid}", flush=True)
PY
}

echo "==> build-profile: launching once, LLVM_PROFILE_FILE=$LLVM_PROFILE_FILE"
launch_log="$out/launch.log"
if [[ -n "${CMUX_PGO_LAUNCHER:-}" ]]; then
  launch_status=0
  "$CMUX_PGO_LAUNCHER" "$app" "$out" "$timeout" | tee "$launch_log" || launch_status=$?
else
  launch_status=0
  CMUX_PGO_ROOT="$root" default_launcher "$app" "$out" "$timeout" | tee "$launch_log" || launch_status=$?
fi
pid="$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$launch_log" | tail -n 1)"
if [[ -z "$pid" ]]; then
  echo "error: the launch started no app (status $launch_status); see $launch_log" >&2
  exit 1
fi
if (( launch_status != 0 )); then
  echo "error: the launch of pid $pid failed (status $launch_status); see $launch_log" >&2
  exit 1
fi

profraw="$out/cmux-next-${pid}.profraw"
if [[ ! -s "$profraw" ]]; then
  echo "error: the app (pid $pid) wrote no profile at $profraw: it did not exit through exit()" >&2
  exit 1
fi
if [[ -n "${CMUX_PGO_LLVM_PROFDATA:-}" ]]; then
  profdata=("$CMUX_PGO_LLVM_PROFDATA")
else
  profdata=(xcrun llvm-profdata)
fi
summary="$("${profdata[@]}" show "$profraw")" || {
  echo "error: llvm-profdata cannot read $profraw" >&2
  exit 1
}
functions="$(sed -n 's/^Total functions: *\([0-9][0-9]*\)$/\1/p' <<<"$summary" | head -n 1)"
max_count="$(sed -n 's/^Maximum function count: *\([0-9][0-9]*\)$/\1/p' <<<"$summary" | head -n 1)"
if [[ -z "$functions" || "$functions" -eq 0 || -z "$max_count" || "$max_count" -eq 0 ]]; then
  echo "error: $profraw has no counts (functions ${functions:-?}, maximum count ${max_count:-?})" >&2
  exit 1
fi
echo "==> build-profile: ok: $profraw ($(wc -c <"$profraw" | tr -d ' ') bytes, $functions functions, maximum count $max_count)"
