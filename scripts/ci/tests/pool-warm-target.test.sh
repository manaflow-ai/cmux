#!/usr/bin/env bash
# scripts/ci/pool-warm-target.sh: a pool runner's kept Cargo target. A real three-crate workspace
# (app depends on core; side depends on nothing) is built, "checked out again" (every source gets a
# new mtime), restored, and built again; Cargo's own Compiling/Fresh lines are the verdict:
# - unchanged bytes with new mtimes: nothing recompiles;
# - a changed core: core and its dependent app recompile, side stays fresh, and app prints the change;
# - a job that never recorded (cancelled): its manifest is gone, so every workspace crate rebuilds;
# - not a pool runner: no CARGO_TARGET_DIR at all;
# - a Blacksmith runner with the job's sticky disk mounted: the same, on the disk.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v cargo >/dev/null || fail "cargo is required"

repo="$TMP/repo"
mkdir -p "$repo/scripts/ci" "$repo/ws/core/src" "$repo/ws/app/src" "$repo/ws/side/src" "$TMP/home"
cp "$ROOT/scripts/ci/pool-warm-target.sh" "$repo/scripts/ci/"
cp "$ROOT/scripts/blacksmith-testbox-source-mtimes.py" "$repo/scripts/"
cat > "$repo/ws/Cargo.toml" <<'EOF'
[workspace]
members = ["core", "app", "side"]
resolver = "2"
EOF
printf '[package]\nname = "core"\nversion = "0.1.0"\nedition = "2021"\n' > "$repo/ws/core/Cargo.toml"
printf '[package]\nname = "side"\nversion = "0.1.0"\nedition = "2021"\n' > "$repo/ws/side/Cargo.toml"
printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\ncore = { path = "../core" }\n' \
  > "$repo/ws/app/Cargo.toml"
echo 'pub fn value() -> u32 { 1 }' > "$repo/ws/core/src/lib.rs"
echo 'pub fn side() -> u32 { 7 }' > "$repo/ws/side/src/lib.rs"
echo 'fn main() { println!("{}", core::value()); }' > "$repo/ws/app/src/main.rs"
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init

pool() {
  : > "$TMP/env"
  env -u CARGO_TARGET_DIR RUNNER_NAME="${RUNNER:-cmux-runner-pool-test-1}" HOME="$TMP/home" GITHUB_ENV="$TMP/env" \
    GITHUB_OUTPUT="$TMP/out" CMUX_POOL_WARM_TARGET_MIN_FREE_GIB=0 ${TARGET:+CARGO_TARGET_DIR="$TARGET"} \
    ${DISK:+CMUX_POOL_WARM_TARGET_TEST_MOUNTED="${MOUNTED-$DISK}"} \
    bash "$repo/scripts/ci/pool-warm-target.sh" "$@" fast-tier-cargo ${DISK:+"$DISK"}
}
restore() { pool restore > "$TMP/restore.log"; TARGET=$(sed -n 's/^CARGO_TARGET_DIR=//p' "$TMP/env"); }
build() {
  (cd "$repo/ws" && CARGO_TARGET_DIR="$TARGET" CARGO_INCREMENTAL=0 cargo build --offline -v 2>&1) > "$TMP/build.log"
  compiled=$(grep -cE '^ +Compiling ' "$TMP/build.log" || true)
  fresh=$(grep -cE '^ +Fresh ' "$TMP/build.log" || true)
}
# A fresh checkout: the same path, every file and directory dated now.
checkout_again() { sleep 1.1; find "$repo/ws" -path "$repo/ws/target" -prune -o -exec touch {} +; }

restore
[[ "$TARGET" == "$TMP/home/.cache/cmux-next-ci/pool-cargo/fast-tier-cargo/"*/rust-* ]] || fail "the tree is under HOME, got $TARGET"
grep -q "miss (no recorded build" "$TMP/restore.log" || fail "an empty tree is a miss"
grep -qx "linked=true" "$TMP/out" || fail "restore says it linked"
build; [[ $compiled == 3 ]] || fail "cold: 3 crates compile, got $compiled"
pool record > /dev/null

checkout_again; restore
grep -q "hit" "$TMP/restore.log" || fail "a recorded tree is a hit"
build; [[ $compiled == 0 && $fresh == 3 ]] || fail "unchanged bytes with new mtimes: 0 compiled, 3 fresh; got $compiled/$fresh"
pool record > /dev/null

checkout_again; echo 'pub fn value() -> u32 { 2 }' > "$repo/ws/core/src/lib.rs"; restore
build
grep -qE '^ +Compiling core ' "$TMP/build.log" || fail "the changed crate recompiles"
grep -qE '^ +Compiling app ' "$TMP/build.log" || fail "its dependent recompiles"
grep -qE '^ +Fresh side ' "$TMP/build.log" || fail "an unrelated crate stays fresh"
[[ $compiled == 2 ]] || fail "a changed core: 2 compiled, got $compiled"
[[ "$("$TARGET/debug/app")" == 2 ]] || fail "the rebuilt app prints the change"
pool record > /dev/null

# A job that restored and changed the tree but never recorded (cancelled): the next one trusts nothing.
checkout_again; restore
echo 'pub fn value() -> u32 { 3 }' > "$repo/ws/core/src/lib.rs"; build
echo 'pub fn value() -> u32 { 2 }' > "$repo/ws/core/src/lib.rs"
checkout_again; restore
grep -q "miss (no recorded build" "$TMP/restore.log" || fail "an unrecorded job leaves no manifest"
build; [[ $compiled == 3 ]] || fail "after an unrecorded job every workspace crate rebuilds, got $compiled"
[[ "$("$TARGET/debug/app")" == 2 ]] || fail "and the app is the checked-out one"

# An empty pool tree with the R2 fallback on: not linked, so the R2 cargo restore runs.
rm -rf "$TMP/home/.cache"; : > "$TMP/out"; TARGET=""
CMUX_POOL_WARM_TARGET_MISS_R2=1 pool restore > "$TMP/restore.log"
grep -q "R2 cargo build restores instead" "$TMP/restore.log" || fail "an empty pool tree defers to R2"
[[ ! -s "$TMP/env" && ! -s "$TMP/out" ]] || fail "a deferred miss links nothing"

# Anywhere else: nothing linked, nothing recorded.
: > "$TMP/out"
RUNNER=blacksmith-4vcpu-ubuntu-2404 TARGET="" pool restore > "$TMP/restore.log"
[[ ! -s "$TMP/env" && ! -s "$TMP/out" ]] || fail "a non-pool runner gets no warm target"
RUNNER=blacksmith-4vcpu-ubuntu-2404 pool record | grep -q "nothing to record" || fail "a non-pool runner records nothing"
TARGET="$TMP/elsewhere" pool record | grep -q "nothing to record" || fail "a foreign CARGO_TARGET_DIR is never recorded"
# A Blacksmith runner with the job's sticky disk mounted: the tree is on the disk, keyed by the
# workspace path only (every Blacksmith runner has another name), and it is just as incremental.
export RUNNER=blacksmith-8vcpu-ubuntu-2404-a DISK="$TMP/disk"; mkdir -p "$DISK"; TARGET=""
restore
[[ "$TARGET" == "$DISK/fast-tier-cargo/"*/rust-* ]] || fail "the tree is on the disk, got $TARGET"
grep -q "miss (no recorded build" "$TMP/restore.log" || fail "an empty disk is a miss"
build; [[ $compiled == 3 ]] || fail "disk cold: 3 crates compile, got $compiled"
pool record | grep -q "the sticky disk" || fail "the disk tree records"
checkout_again; RUNNER=blacksmith-8vcpu-ubuntu-2404-b; first=$TARGET; TARGET=""; restore
[[ "$TARGET" == "$first" ]] || fail "another Blacksmith runner finds the same tree"
grep -q "hit" "$TMP/restore.log" || fail "a recorded disk is a hit"
build; [[ $compiled == 0 && $fresh == 3 ]] || fail "disk, unchanged bytes: 0 compiled, 3 fresh; got $compiled/$fresh"
pool record > /dev/null
checkout_again; echo 'pub fn side() -> u32 { 8 }' > "$repo/ws/side/src/lib.rs"; TARGET=""; restore
build; [[ $compiled == 1 ]] && grep -qE '^ +Compiling side ' "$TMP/build.log" \
  || fail "disk, a changed leaf: only it recompiles, got $compiled"
pool record > /dev/null
# The same path, not mounted: nothing linked.
: > "$TMP/out"; TARGET=""; MOUNTED=none pool restore > "$TMP/restore.log"
[[ ! -s "$TMP/env" && ! -s "$TMP/out" ]] || fail "an unmounted disk path gets no warm target"
unset RUNNER DISK
echo "pool-warm-target: ok"
