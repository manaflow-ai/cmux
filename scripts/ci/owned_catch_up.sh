#!/usr/bin/env bash
# owned_catch_up.sh ROOT STATE
#
# Build the checkout in the current directory (main's head, with submodules)
# into owned root ROOT's kept build state, the way ci-macos.yml compile
# admission's owned path does for a main dispatch: check, prefer (kept seeds
# only), adopt, record, canonical-build, keep with MERGED_ONTO = HEAD, save.
#
# glaeda-idle-warm runs it on an idle owned mini whose kept build is far from
# main (cmuxterm-hq#661 WS6), so the next pull request admitted to that root
# starts near: it compiles its own diff and not main's drift as well. glaeda
# holds the root's capacity tokens while this runs and kills its process group
# the moment a job starts; every step below is safe to kill:
#
# - The kept state changes only in `keep`, after a successful compile. A kill
#   before it leaves the store as it was; a kill inside it leaves the old kept
#   build or one stamped without a fingerprint, which no job adopts (the next
#   job takes a seed instead). It never leaves a half-copied build marked warm.
# - The canonical root's src and DerivedData are the root token holder's
#   scratch space: every compile admission clears and recreates them.
#
# ROOT is 1 (/private/tmp/cmux-ci, store STATE) or N (/private/tmp/cmux-ci-N,
# store STATE/cmux-ci-N); packages live in STATE for every root. The Xcode is
# CMUX_CI_XCODE_APP, which glaeda passes from the runner's toolchain pin. The
# host-wide xcode-select default is left alone (CMUX_CI_SKIP_XCODE_SELECT).
# Nothing is uploaded, and no GitHub token is used: seed history comes from
# the checkout's own git (CMUX_SEED_GIT_DIR) and seeds from the public bucket.
#
# With CMUX_CATCH_UP_LOG, xcodebuild's output goes there. Prints one JSON line
# last: {"kept": "true"|"false", "root": N, "head": SHA, "start": ..., ...}.
set -euo pipefail

usage() { echo "usage: $0 ROOT STATE (run from a checkout of the commit to build)" >&2; exit 64; }
[ "$#" -eq 2 ] || usage
root_number="$1"
state="$2"
case "$root_number" in [1-9]|[1-9][0-9]) ;; *) usage ;; esac
case "$state" in /*) ;; *) usage ;; esac
: "${CMUX_CI_XCODE_APP:?CMUX_CI_XCODE_APP names the Xcode to build with}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace="$(git rev-parse --show-toplevel)"
[ "$workspace" = "$(cd "$here/../.." && pwd)" ] || { echo "run from the checkout this script is in" >&2; exit 64; }
cd "$workspace"
head="$(git rev-parse HEAD)"

if [ "$root_number" = 1 ]; then
  root=/private/tmp/cmux-ci
  store="$state"
else
  root="/private/tmp/cmux-ci-$root_number"
  store="$state/cmux-ci-$root_number"
fi
export CMUX_CI_CANONICAL_ROOT="$root"
export CMUX_CI_CANONICAL_SRC="$root/src"
export CMUX_COMPILE_ADMISSION_DERIVED_DATA="$root/derived-data-compile-admission"
export CMUX_COMPILE_ADMISSION_CAS="$root/compile-admission-cas"
export CMUX_SKIP_ZIG_BUILD=1
export CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=26
export CMUX_CI_SKIP_XCODE_SELECT=1
# The seed key's runner fields, as compile admission sees them on an owned mini.
export RUNNER_OS=macOS RUNNER_ARCH=ARM64
export CMUX_SEED_GIT_DIR="$workspace/.git"
export CMUX_SEED_LOCAL_CACHE="$store/seeds"
export CI_CACHE_R2_PUBLIC_URL="${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}"
unset GITHUB_ENV GITHUB_OUTPUT GITHUB_REPOSITORY GH_TOKEN GITHUB_TOKEN
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
dd="$CMUX_COMPILE_ADMISSION_DERIVED_DATA"
log="${CMUX_CATCH_UP_LOG:-/dev/null}"

started="$(date +%s)"
phase=setup
adopted=cold
result() {
  local kept="$1" reason="$2"
  printf '{"kept": "%s", "root": %s, "head": "%s", "start": "%s", "phase": "%s", "seconds": %s, "reason": "%s"}\n' \
    "$kept" "$root_number" "$head" "$adopted" "$phase" "$(( $(date +%s) - started ))" "$reason"
}
fail() { result false "$1"; exit 1; }
# A field of a step's JSON line; empty when the step printed none.
field() {
  python3 -c 'import json,sys
try: print(json.loads(sys.argv[1]).get(sys.argv[2], ""))
except ValueError: print("")' "$1" "$2"
}
last_json() { grep '^{' | tail -n 1; }

scripts/ci/clear-dirs.sh "$dd" "$CMUX_COMPILE_ADMISSION_CAS"
CMUX_CI_XCODE_APP="$CMUX_CI_XCODE_APP" ./scripts/select-ci-xcode.sh >>"$log" 2>&1 || fail "select-ci-xcode"
export DEVELOPER_DIR="$CMUX_CI_XCODE_APP/Contents/Developer"
./scripts/install-rust-ci.sh >>"$log" 2>&1 || fail "install-rust-ci"

phase=check
fingerprint="$(scripts/ci/compile-app-host-test-product.sh canonical-fingerprint "$dd")" || fail "fingerprint"
checked="$(python3 scripts/ci/owned_build_state.py check "$store" "$fingerprint" "$workspace" "$state" | last_json)" \
  || checked='{}'
warm="$(field "$checked" warm)"
prefer=false seed_key=""
if [ "$warm" = true ]; then
  # Kept seeds only (no MAX_DISTANCE): the same comparison a job runs, without a GitHub compare.
  preferred="$(python3 scripts/ci/owned_build_state.py prefer "$store" "$workspace" \
    "admission-derived-data-v1-$RUNNER_OS-$RUNNER_ARCH-$fingerprint-" "$head" | last_json)" || preferred='{}'
  prefer="$(field "$preferred" prefer)"
  [ "$(field "$preferred" local)" = true ] && seed_key="$(field "$preferred" seed_key)"
fi

phase=resolve
GHOSTTYKIT_ARCHIVE_CACHE_DIR="$state/ghosttykit-archives" ./scripts/download-prebuilt-ghosttykit.sh >>"$log" 2>&1 \
  || fail "ghosttykit"
python3 scripts/ci/sanitize-xcode-source-packages-cache.py .ci-source-packages >>"$log" 2>&1 || fail "sanitize"
scripts/ci/clear-dirs.sh "$dd"
CMUX_CI_MOVE_SOURCE_PACKAGES=1 scripts/ci/compile-app-host-test-product.sh canonical-resolve \
  "$dd" "$workspace/.ci-source-packages" >>"$log" 2>&1 || fail "resolve"

phase=adopt
seed_hit=false
if [ "$warm" != true ] || [ "$prefer" = true ]; then
  seeded="$(CMUX_SEED_EXACT="$seed_key" python3 scripts/ci/seed_derived_data.py adopt "$CMUX_CI_CANONICAL_SRC" "$dd" \
    "admission-derived-data-v1-$RUNNER_OS-$RUNNER_ARCH-$fingerprint-" "$head" | last_json)" || seeded='{}'
  seed_hit="$(field "$seeded" hit)"
  [ "$seed_hit" = true ] && adopted="seed:$(field "$seeded" key)"
fi
if [ "$warm" = true ] && [ "$seed_hit" != true ]; then
  python3 scripts/ci/owned_build_state.py adopt "$store" "$dd" "$CMUX_CI_CANONICAL_SRC" >>"$log" 2>&1 \
    && adopted=kept
fi
python3 scripts/ci/owned_build_state.py record "$CMUX_CI_CANONICAL_SRC" "$dd" >>"$log" 2>&1 || fail "record"

phase=build
status=0
scripts/ci/compile-app-host-test-product.sh canonical-build "$dd" "$workspace/.ci-source-packages" \
  "$CMUX_COMPILE_ADMISSION_CAS" "$log" >>"$log" 2>&1 || status=$?
defaults delete com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges >/dev/null 2>&1 || true
[ "$status" = 0 ] || fail "compile exit $status"

phase=keep
python3 scripts/ci/owned_build_state.py keep "$store" "$dd" "$fingerprint" "$head" >>"$log" 2>&1 || fail "keep"
python3 scripts/ci/owned_build_state.py save "$store" "$CMUX_CI_CANONICAL_SRC/.ci-source-packages" "$workspace" \
  "$state" >>"$log" 2>&1 || true
phase=done
result true "kept main's head"
