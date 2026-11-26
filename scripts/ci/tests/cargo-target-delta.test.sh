#!/usr/bin/env bash
# scripts/ci/cargo-target-delta.sh: the per-commit workspace delta on top of the R2 dependency entry.
# A real three-crate workspace (app depends on core; side depends on nothing). Every leg starts on a
# new runner: an empty target, a new checkout (every source dated now), the last leg's delta.
# Cargo's own Compiling/Fresh lines are the verdict:
# - no delta: every crate compiles, and the delta it packs makes the next leg compile nothing;
# - a leg that compiled nothing still packs everything it applied, so the leg after it is warm too;
# - a changed core: core and app recompile, side stays fresh, app prints the change;
# - pack without apply packs nothing;
# - a target linked to a pool tree (the darwin leg) packs through the link, and stays warm.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v cargo >/dev/null || fail "cargo is required"
export RUNNER_TEMP="$TMP/runner-temp"; mkdir -p "$RUNNER_TEMP"
# The fixture's target is ws/target; a runner's shared CARGO_TARGET_DIR would build elsewhere.
unset CARGO_TARGET_DIR

repo="$TMP/repo"
mkdir -p "$repo/scripts/ci" "$repo/ws/core/src" "$repo/ws/app/src" "$repo/ws/side/src"
cp "$ROOT/scripts/ci/cargo-target-delta.sh" "$repo/scripts/ci/"
cp "$ROOT/scripts/blacksmith-testbox-source-mtimes.py" "$repo/scripts/"
cat > "$repo/ws/Cargo.toml" <<'TOML'
[workspace]
members = ["core", "app", "side"]
resolver = "2"
TOML
printf '[package]\nname = "core"\nversion = "0.1.0"\nedition = "2021"\n' > "$repo/ws/core/Cargo.toml"
printf '[package]\nname = "side"\nversion = "0.1.0"\nedition = "2021"\n' > "$repo/ws/side/Cargo.toml"
printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\ncore = { path = "../core" }\n' \
  > "$repo/ws/app/Cargo.toml"
echo 'pub fn value() -> u32 { 1 }' > "$repo/ws/core/src/lib.rs"
echo 'pub fn side() -> u32 { 7 }' > "$repo/ws/side/src/lib.rs"
echo 'fn main() { println!("{}", core::value()); }' > "$repo/ws/app/src/main.rs"
git -C "$repo" init -q && git -C "$repo" add -A && git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init

delta() { bash "$repo/scripts/ci/cargo-target-delta.sh" "$@" aarch64-apple-darwin; }
target="$repo/ws/target"; stamp="$RUNNER_TEMP/delta.stamp"; saved="$TMP/r2"; mkdir -p "$saved"
# A new runner: no target, every source dated now, the saved delta "restored from R2" into a scratch dir.
leg() {
  sleep 1.1; rm -rf "$target" "$TMP/restored" "$stamp" "$stamp.list"
  find "$repo/ws" -exec touch {} +
  if [[ -d "$saved/delta" ]]; then cp -a "$saved/delta" "$TMP/restored"; fi
  delta apply "$target" "$TMP/restored" "$stamp" > "$TMP/apply.log"
  (cd "$repo/ws" && CARGO_INCREMENTAL=0 cargo build --offline -v 2>&1) > "$TMP/build.log"
  compiled=$(grep -cE '^ +Compiling ' "$TMP/build.log" || true)
  fresh=$(grep -cE '^ +Fresh ' "$TMP/build.log" || true)
  delta pack "$target" "$stamp" "$TMP/out" > "$TMP/pack.log"
  rm -rf "$saved/delta"; cp -a "$TMP/out" "$saved/delta"
}

leg
grep -q "miss" "$TMP/apply.log" || fail "no delta is a miss"
[[ $compiled == 3 ]] || fail "cold: 3 crates compile, got $compiled"
grep -q "cargo delta: packed" "$TMP/pack.log" || fail "pack reports its size"
[[ -f "$saved/delta/.cmux-testbox-source-mtimes.tsv" ]] || fail "the delta carries the source mtimes"

leg
grep -q "hit" "$TMP/apply.log" || fail "a saved delta is a hit"
[[ $compiled == 0 && $fresh == 3 ]] || fail "new runner, unchanged bytes: 0 compiled, 3 fresh; got $compiled/$fresh"
[[ ! -e "$TMP/restored" ]] || fail "apply removes the restored scratch copy"

# The leg that compiled nothing packed what it applied: the next one is warm as well.
leg
[[ $compiled == 0 && $fresh == 3 ]] || fail "a delta packed by a fresh leg stays warm; got $compiled/$fresh"

echo 'pub fn value() -> u32 { 2 }' > "$repo/ws/core/src/lib.rs"
git -C "$repo" -c user.name=t -c user.email=t@t commit -qam two
leg
grep -qE '^ +Compiling core ' "$TMP/build.log" || fail "the changed crate recompiles"
grep -qE '^ +Compiling app ' "$TMP/build.log" || fail "its dependent recompiles"
grep -qE '^ +Fresh side ' "$TMP/build.log" || fail "an unrelated crate stays fresh"
[[ $compiled == 2 ]] || fail "a changed core: 2 compiled, got $compiled"
[[ "$("$target/debug/app")" == 2 ]] || fail "the rebuilt app prints the change"
leg
[[ $compiled == 0 ]] || fail "after the change the delta is warm again, got $compiled"

rm -f "$stamp"
delta pack "$target" "$stamp" "$TMP/none" | grep -q "nothing packed" || fail "pack without apply packs nothing"
[[ ! -e "$TMP/none" ]] || fail "and writes no tree"
# The darwin pool leg: machine-channel-warm-target.sh restore moves the applied target into the
# runner slot's tree and links cmux-tui/target to it, so pack reads the delta through a link
# (job 140189679068 packed nothing: record had removed the tree behind the link).
pool="$TMP/pool/target"
pool_leg() {
  sleep 1.1; rm -rf "$target" "$TMP/restored" "$stamp" "$stamp.list" "$TMP/pool"
  find "$repo/ws" -exec touch {} +
  if [[ -d "$saved/delta" ]]; then cp -a "$saved/delta" "$TMP/restored"; fi
  delta apply "$target" "$TMP/restored" "$stamp" > "$TMP/apply.log"
  mkdir -p "$TMP/pool"; mv "$target" "$pool"; ln -s "$pool" "$target"
  (cd "$repo/ws" && CARGO_INCREMENTAL=0 cargo build --offline -v 2>&1) > "$TMP/build.log"
  compiled=$(grep -cE '^ +Compiling ' "$TMP/build.log" || true)
  delta pack "$target" "$stamp" "$TMP/out" > "$TMP/pack.log"
  rm -rf "$saved/delta"; cp -a "$TMP/out" "$saved/delta"
}
rm -rf "$saved/delta"
pool_leg
[[ $compiled == 3 ]] || fail "pool, cold: 3 crates compile, got $compiled"
grep -q "cargo delta: packed" "$TMP/pack.log" || fail "pool: pack reads the target through its link: $(cat "$TMP/pack.log")"
grep -qE '\(target [0-9.]+[KMG]' "$TMP/pack.log" || fail "pool: the target size is the linked tree's: $(cat "$TMP/pack.log")"
pool_leg
grep -q "hit" "$TMP/apply.log" || fail "pool: the linked leg's delta is a hit"
[[ $compiled == 0 ]] || fail "pool: the linked leg's delta is warm, got $compiled"
rm -rf "$TMP/pool"
delta pack "$target" "$stamp" "$TMP/none" | grep -q "a link to the missing $pool); nothing packed" \
  || fail "pool: a tree removed behind the link is named"
rm -f "$target"

# TRIPLE host (the cmux-next fast tier) keeps this machine's CPU: the delta records the real fingerprint.
rm -rf "$saved/delta"
delta() { bash "$repo/scripts/ci/cargo-target-delta.sh" "$@" host; }
leg
[[ $compiled == 3 ]] || fail "host, cold: 3 crates compile, got $compiled"
host_cpu=$(python3 -I -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("m", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.cpu_fingerprint())' "$ROOT/scripts/blacksmith-testbox-source-mtimes.py")
[[ -n "$host_cpu" && "$(cat "$saved/delta/.cmux-testbox-cpu" 2>/dev/null)" == "$host_cpu" ]] || fail "host: the delta records this CPU"
leg
[[ $compiled == 0 && $fresh == 3 ]] || fail "host, same CPU: 0 compiled, 3 fresh; got $compiled/$fresh"
echo "cargo-target-delta: ok"
