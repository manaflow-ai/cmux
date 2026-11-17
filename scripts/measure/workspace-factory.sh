#!/usr/bin/env bash
# A fresh throwaway workspace per job against today's step workspaces, on one
# fleet Mac, for one real cmux step: the swift-package-tests prebuild of a
# package (`swift build --build-tests`, as package-test-lane.sh prebuild-one
# runs it). hq docs/rfd/0005-ephemeral-workers.md has the design.
#
# Usage: workspace-factory.sh [PACKAGE] [JOBS]
#   PACKAGE  a Packages/ path (default Packages/iOS/CmuxMobileSSH: swift-nio,
#            swift-crypto and a local path dependency, so a cold build fetches
#            and compiles a real dependency closure)
#   JOBS     factory jobs after the seed (default 3)
#
# Arms, each at one fixed path (SwiftPM keys .build by absolute path):
#   cold     today with no warm slot: a fresh copy of the tree, the step's
#            own HOME caches; the tree is removed after, the caches are not.
#   slot     today's warm step slot (hq step_warm.go): the cold tree kept and
#            built again as the next job of the same commit would.
#   seed     the trusted seed build: a fresh tree, every cache inside it.
#   factory  per job: wsfactory create (an APFS clone of the seed at the
#            seed's path, HOME, TMPDIR and SwiftPM caches in a scratch dir),
#            the build, wsfactory destroy. Nothing of the job survives it.
#
# Every result is a line `WSFACTORY {json}` (cmux-bench workspace-factory
# reads them); `WSFACTORY-SUMMARY {json}` closes the run. Everything this
# script creates is under one root that it removes on exit, and the last line
# reports the volume's free space against the start (disk left behind).
set -euo pipefail

pkg="${1:-Packages/iOS/CmuxMobileSSH}"
jobs="${2:-3}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
factory_src="$repo/scripts/measure/workspace-factory"
[ -f "$repo/$pkg/Package.swift" ] || { echo "workspace-factory: no package at $pkg" >&2; exit 2; }
[[ "$jobs" =~ ^[1-9][0-9]?$ ]] || { echo "workspace-factory: JOBS must be 1-99" >&2; exit 2; }

if [ -n "${CMUX_CI_XCODE_APP:-}" ]; then
  export DEVELOPER_DIR="$CMUX_CI_XCODE_APP/Contents/Developer"
fi

# One root on the data volume (clonefile needs source and clone on one volume),
# never under the step's checkout, so the step's own cleanup is not what we measure.
# Not under TMPDIR: TMPDIR is one of the places measured for what a build leaves outside its tree.
mkdir -p "$HOME/.cache"
root="$(mktemp -d "$HOME/.cache/wsfactory.XXXXXX")"
root="$(cd "$root" && pwd -P)"
cleanup() {
  chmod -R u+w "$root" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT
# df's own number, before anything is built, so the factory's cargo target is in the end-to-start delta too.
df_free() { df -k "$root" | awk 'NR==2 {print $4 * 1024}'; }
start_free=$(df_free)

now_ms() { python3 -c 'import time; print(time.time_ns() // 1000000)'; }
emit() { printf 'WSFACTORY %s\n' "$1"; }

# The factory itself: std-only Rust, built here so the step needs no published binary.
build_started=$(now_ms)
cargo build --quiet --release --manifest-path "$factory_src/Cargo.toml" --target-dir "$root/factory-target"
wsf="$root/factory-target/release/wsfactory"
echo "workspace-factory: built wsfactory in $(( $(now_ms) - build_started )) ms"

# Where a SwiftPM build with the step's default HOME leaves state outside its tree.
home_caches=(
  "$HOME/Library/Caches/org.swift.swiftpm"
  "$HOME/Library/org.swift.swiftpm"
  "$HOME/.swiftpm"
  "$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"
  "$(cd "${TMPDIR:-/tmp}" && pwd -P)"
)
home_bytes() {
  "$wsf" usage "${home_caches[@]}" | python3 -c '
import json, sys
print(sum(e["bytes"] for e in json.load(sys.stdin)["paths"] if e["exists"]))'
}
free_bytes() { "$wsf" statfs "$root" | python3 -c 'import json, sys; print(json.load(sys.stdin)["free_bytes"])'; }
field() { python3 -c 'import json, sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }

# build TREE LOG [SCRATCH]: the step's command in TREE/<pkg below Packages/>; prints "MS COMPILED STATUS".
# With SCRATCH (a dir with home/, tmp/, cache/) every SwiftPM cache, config and HOME write goes there:
# HOME alone does not move SwiftPM's caches on macOS (it asks the user database), so the flags say it too.
build() {
  local tree="$1" log="$2" scratch="${3:-}" started status=0
  local envs=() flags=()
  if [ -n "$scratch" ]; then
    envs=(HOME="$scratch/home" TMPDIR="$scratch/tmp/" XDG_CACHE_HOME="$scratch/cache" CFFIXED_USER_HOME="$scratch/home")
    flags=(--cache-path "$scratch/cache/swiftpm" --config-path "$scratch/home/swiftpm-config"
      --security-path "$scratch/home/swiftpm-security")
  fi
  started=$(now_ms)
  (cd "$tree/${pkg#Packages/}" && env ${envs[@]+"${envs[@]}"} swift build --build-tests ${flags[@]+"${flags[@]}"}) \
    > "$log" 2>&1 < /dev/null || status=$?
  local ms=$(( $(now_ms) - started ))
  local compiled
  compiled=$(grep -cE '^\[[0-9]+/[0-9]+\] Compiling ' "$log" || true)
  echo "$ms $compiled $status"
}

# A fresh copy of the source tree at PATH, as a step's checkout gives it: the whole
# Packages/ dir, since packages reach their siblings by relative path.
fresh_tree() {
  mkdir -p "$(dirname "$1")"
  cp -cR "$repo/Packages" "$1" 2>/dev/null || cp -R "$repo/Packages" "$1"
  rm -rf "$1"/*/*/.build
}

cold_compiled=0

# cold: today's step with no warm slot.
tree="$root/cold/Packages"
fresh_tree "$tree"
home_before=$(home_bytes); free_before=$(free_bytes)
read -r ms compiled status < <(build "$tree" "$root/cold.log")
[ "$status" -eq 0 ] || { tail -40 "$root/cold.log" >&2; echo "workspace-factory: cold build failed ($status)" >&2; exit 1; }
cold_compiled=$compiled
slot_bytes=$("$wsf" usage "$root/cold" | python3 -c 'import json, sys; print(json.load(sys.stdin)["paths"][0]["bytes"])')
emit "{\"arm\":\"cold\",\"job\":1,\"start_ms\":0,\"build_ms\":$ms,\"compiled\":$compiled,\"home_growth_bytes\":$(( $(home_bytes) - home_before )),\"tree_bytes\":$slot_bytes}"

# slot: the same tree kept for the next job of the same commit (the cold tree stays, as a slot does).
read -r ms compiled status < <(build "$tree" "$root/slot.log")
[ "$status" -eq 0 ] || { tail -40 "$root/slot.log" >&2; echo "workspace-factory: slot build failed ($status)" >&2; exit 1; }
emit "{\"arm\":\"slot\",\"job\":1,\"start_ms\":0,\"build_ms\":$ms,\"compiled\":$compiled,\"left_bytes\":$slot_bytes}"
# Today the slot stays on disk after the job; here it goes so the run itself leaves nothing.
chmod -R u+w "$root/cold"; rm -rf "$root/cold"
emit "{\"arm\":\"cold\",\"job\":1,\"left_bytes\":$(( free_before - $(free_bytes) )),\"home_left_bytes\":$(( $(home_bytes) - home_before ))}"

# seed: a trusted build at the factory's fixed path, every cache inside the tree's root.
ws="$root/ws"
mkdir -p "$root/seed-scratch"/{home,tmp,cache}
fresh_tree "$ws/Packages"
read -r ms compiled status < <(build "$ws/Packages" "$root/seed.log" "$root/seed-scratch")
[ "$status" -eq 0 ] || { tail -40 "$root/seed.log" >&2; echo "workspace-factory: seed build failed ($status)" >&2; exit 1; }
rm -rf "$root/seed-scratch"
published=$("$wsf" seed publish --root "$root/factory" --name seed --from "$ws")
emit "{\"arm\":\"seed\",\"job\":0,\"build_ms\":$ms,\"compiled\":$compiled,\"publish_ms\":$(field "$published" ms),\"seed_bytes\":$(field "$published" bytes),\"seed_files\":$(field "$published" files)}"

# factory: create, build, destroy, per job.
for j in $(seq 1 "$jobs"); do
  home_before=$(home_bytes); free_before=$(free_bytes)
  created=$("$wsf" create --root "$root/factory" --seed seed --job "job-$j" --owner-pid $$)
  read -r ms compiled status < <(build "$(field "$created" path)/Packages" "$root/factory-$j.log" "$(field "$created" scratch)")
  [ "$status" -eq 0 ] || { tail -40 "$root/factory-$j.log" >&2; echo "workspace-factory: factory job $j failed ($status)" >&2; exit 1; }
  destroyed=$("$wsf" destroy --root "$root/factory" --job "job-$j")
  verify_ok=$("$wsf" seed verify --root "$root/factory" --name seed | python3 -c 'import json, sys; print(str(json.load(sys.stdin)["ok"]).lower())') || verify_ok=false
  emit "{\"arm\":\"factory\",\"job\":$j,\"start_ms\":$(field "$created" clone_ms),\"clone\":\"$(field "$created" clone)\",\"build_ms\":$ms,\"compiled\":$compiled,\"destroy_ms\":$(field "$destroyed" ms),\"left_bytes\":$(( free_before - $(free_bytes) )),\"home_left_bytes\":$(( $(home_bytes) - home_before )),\"seed_unchanged\":$verify_ok}"
done

"$wsf" seed remove --root "$root/factory" --name seed > /dev/null
leftover=$(find "$root/factory" -mindepth 2 2>/dev/null | wc -l | tr -d ' ')
printf 'WSFACTORY-SUMMARY {"package":"%s","jobs":%s,"cold_compiled":%s,"factory_root_entries_left":%s,"host":"%s","xcode":"%s"}\n' \
  "$pkg" "$jobs" "$cold_compiled" "$leftover" "$(hostname -s)" "$(xcodebuild -version 2>/dev/null | head -1)"
cleanup
trap - EXIT
echo "WSFACTORY-END {\"run_left_bytes\":$(( start_free - $(df -k "$HOME/.cache" | awk 'NR==2 {print $4 * 1024}') ))}"
