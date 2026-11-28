#!/usr/bin/env bash
# The legacy Computer Use helper's Rust unit tests with cmux's patches applied (ask-3cf710da4e). No other
# step builds or tests that helper, and its crates need a macOS SDK, so this runs on a fleet Mac. It takes
# scripts/build-cmux-cua.sh, scripts/apply-cmux-cua-patch.sh and every scripts/cmux-cua-*.patch from ref=
# (plus the files build-cmux-cua.sh reads beside them: strip-cmux-cua-rpaths.sh, lib/rust-targets.sh and
# cmux-tui/rust-toolchain.toml) into a temp tree, runs that ref's build-cmux-cua.sh (arm64 only) so it
# materializes the pinned, patched source at CACHE_DIR/build-src-<pin>-<patchdigest>, then runs, in that
# source, with the toolchain cmux-tui pins (the one build-cmux-cua.sh builds the helper with):
#   cargo test -p cmux-cua-core --features cmux-host-consent
#   cargo test -p cmux-cua-platform-macos
# ref= is any commit, so a PR's patch gets a verdict before the PR lands; it defaults to this checkout's HEAD.
#
#   cmux-ci run --class exclusive --measurement --label measure --label macos-26 \
#     --script scripts/measure/cmux-cua-patch-tests.sh --ref SHA \
#     --artifact artifacts/cmux-cua-patch-tests.tgz [--arg=ref=PR_HEAD_SHA] --timeout 3600
#
# Output: CPT lines, and artifacts/cmux-cua-patch-tests.tgz with build.log, one log per crate and
# summary.txt (each crate's `test result:` lines and exit status). Exit: the first failing cargo test's
# status, 0 when both pass, 4 when the source could not be built, 2 on a bad argument.
set -uo pipefail
ref=""
for arg in "$@"; do
  case "$arg" in
    ref=*|--arg=ref=*) ref="${arg#--arg=}"; ref="${ref#ref=}" ;;
    *) echo "cmux-cua-patch-tests.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
[[ -n "$ref" ]] || ref="$(git rev-parse HEAD)"
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "cmux-cua-patch-tests.sh: ref= must be a 40-hex commit SHA" >&2; exit 2; }
out="$root/artifacts/cmux-cua-patch-tests"
rm -rf "$out" "$root/artifacts/cmux-cua-patch-tests.tgz"
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cua-patch-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
note() { echo "CPT $(date -u +%H:%M:%S) $*"; }
finish() {
  [[ -n "${1:-}" ]] && { note "blocked: $1"; printf 'blocked: %s\n' "$1" >>"$out/summary.txt"; }
  [[ -s "$out/summary.txt" ]] && cat "$out/summary.txt"
  tar -czf "$root/artifacts/cmux-cua-patch-tests.tgz" -C "$root/artifacts" cmux-cua-patch-tests
}
printf 'ref %s\n' "$ref" >"$out/summary.txt"

note "STAGE source $ref"
if ! git cat-file -e "$ref^{commit}" 2>/dev/null; then
  # A fleet checkout may have no origin remote: try the fleet's mirror, then origin, then GitHub.
  for source in "${CMUX_FLEET_GIT_MIRROR:-/Users/Shared/cmux-build-fleet/git/cmux.git}" origin https://github.com/manaflow-ai/cmux.git; do
    git fetch --no-recurse-submodules -q "$source" "$ref" >>"$out/fetch.log" 2>&1 && git cat-file -e "$ref^{commit}" 2>/dev/null && break
  done
  git cat-file -e "$ref^{commit}" 2>/dev/null || { cat "$out/fetch.log"; finish "could not fetch $ref"; exit 4; }
fi
tree="$work/tree"
patches=()
while IFS= read -r p; do
  [[ "$p" == scripts/cmux-cua-*.patch ]] && patches+=("$p")
done < <(git ls-tree --name-only "$ref" scripts/)
((${#patches[@]})) || { finish "$ref has no scripts/cmux-cua-*.patch"; exit 4; }
for p in scripts/build-cmux-cua.sh scripts/apply-cmux-cua-patch.sh scripts/strip-cmux-cua-rpaths.sh \
  scripts/lib/rust-targets.sh cmux-tui/rust-toolchain.toml ${patches[@]+"${patches[@]}"}; do
  mkdir -p "$tree/$(dirname "$p")"
  git show "$ref:$p" >"$tree/$p" 2>>"$out/fetch.log" || { finish "$ref has no $p"; exit 4; }
done
chmod +x "$tree"/scripts/*.sh
# The digest build-cmux-cua.sh keys its build source on: its own patch list, in order.
listed="$(bash -c 'eval "$(sed -n "/^CMUX_CUA_PATCH_RELATIVE_PATHS=(/,/^)/p" "$1")"; printf "%s\n" "${CMUX_CUA_PATCH_RELATIVE_PATHS[@]}"' _ \
  "$tree/scripts/build-cmux-cua.sh")"
pin="$(sed -n 's/^CMUX_CUA_PINNED_SHA="\([0-9a-f]*\)"$/\1/p' "$tree/scripts/build-cmux-cua.sh")"
[[ -n "$listed" && "$pin" =~ ^[0-9a-f]{40}$ ]] || { finish "could not read the pin or patch list of $ref's build-cmux-cua.sh"; exit 4; }
for p in ${patches[@]+"${patches[@]}"}; do
  grep -qxF "$p" <<<"$listed" || printf 'warning: %s is not in build-cmux-cua.sh, so it is not applied or tested\n' "$p" >>"$out/summary.txt"
done
digest="$(cd "$tree" && while IFS= read -r p; do cat "$p"; done <<<"$listed" | shasum -a 256 | awk '{print $1}')"
printf 'pin %s\npatches %s\n' "$pin" "$(tr '\n' ' ' <<<"$listed")" >>"$out/summary.txt"

note "STAGE toolchain"
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh >"$out/toolchain.log" 2>&1
export PATH="${PATH}:${CARGO_HOME:-$HOME/.cargo}/bin"
command -v cargo >/dev/null || { finish "no cargo (toolchain.log)"; exit 4; }
# A worker's shared rustup keeps no default toolchain: use the one cmux-tui pins, as build-cmux-cua.sh does.
toolchain="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$tree/cmux-tui/rust-toolchain.toml" | head -1)"
[[ -n "$toolchain" ]] || { finish "no channel in $ref's cmux-tui/rust-toolchain.toml"; exit 4; }
export RUSTUP_TOOLCHAIN="$toolchain"
if command -v rustup >/dev/null; then
  # shellcheck source=scripts/lib/rust-targets.sh
  source "$tree/scripts/lib/rust-targets.sh"
  if declare -F ensure_rust_toolchain >/dev/null; then
    ensure_rust_toolchain "$toolchain" --profile minimal >>"$out/toolchain.log" 2>&1 || { finish "could not install Rust $toolchain (toolchain.log)"; exit 4; }
  fi
fi
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
[[ -n "$SDKROOT" ]] || { finish "cannot resolve the macOS SDK of the selected Xcode"; exit 4; }
export SDKROOT
{ cargo --version; rustc --version; echo "SDKROOT=$SDKROOT"; } >>"$out/summary.txt" 2>&1

note "STAGE build (pin $pin, patch digest $digest)"
cache="${CMUX_CUA_CACHE_DIR:-${HOME:-/tmp}/Library/Caches/cmux/cmux-cua}"
"$tree/scripts/build-cmux-cua.sh" --output "$work/out/cmux-cua" --archs arm64 --cache-dir "$cache" >"$out/build.log" 2>&1 ||
  { tail -40 "$out/build.log"; finish "build-cmux-cua.sh failed (build.log)"; exit 4; }
src="$cache/build-src-$pin-$digest"
cargo_root="$src/libs/cmux-cua/rust"
[[ -f "$cargo_root/Cargo.toml" ]] || { finish "no patched source at $src"; exit 4; }
note "built; patched source $src"

note "STAGE test"
status=0
run_test() {
  local name="$1" rc
  shift
  note "cargo test $*"
  CARGO_TARGET_DIR="$src/.cmux-cargo-target/patch-tests" CARGO_NET_RETRY="${CARGO_NET_RETRY:-5}" \
    cargo test --manifest-path "$cargo_root/Cargo.toml" --locked "$@" 2>&1 | tee "$out/$name.log"
  rc=$?
  {
    echo "== $name (cargo test $*): exit $rc"
    grep -E '^test result:' "$out/$name.log" || echo "no test result: lines"
  } >>"$out/summary.txt"
  ((status == 0 && rc != 0)) && status=$rc
}
run_test cmux-cua-core -p cmux-cua-core --features cmux-host-consent
run_test cmux-cua-platform-macos -p cmux-cua-platform-macos
finish
exit "$status"
