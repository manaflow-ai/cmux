#!/usr/bin/env bash
# CMUX-570 (Leo: "decreasing bundle size"): what folding a shipped Rust program into the multicall bin/cmux saves in
# bytes and costs per process, base against head, from one harness on one Linux runner. Fleet only:
#   cmux-ci test --timeout 7200 --artifact DIR -- bash -c 'set -o pipefail; scripts/measure/fold-hosts.sh [BASE_SHA]'
# or `scripts/bench/cmux-bench fold-hosts --build HEAD_SHA [--arg base=SHA]`.
# BASE_SHA defaults to this checkout's merge base with origin/feat-cmux-next. For each commit it builds, with the
# shipped crates' own release profiles, bin/cmux (cmux-tui) and bin/cmux-tui-host (one cargo invocation, one build
# identity; with `fold-mobile-host` when the commit has it, as the macOS build always does),
# bin/cmux-agent-screen-detection, bin/cmux-cloud and bin/cmux-mobile-host (each its own Cargo workspace; the iPhone
# host with build-mobile-host.sh's fat LTO, one codegen unit and panic=abort), strips every file
# (strip --strip-unneeded) and lays them out as the bundle does: this checkout's link-folded-hosts.sh links the
# names that commit's cmux runs by argv[0]. Then fold-hosts.py samples start time and idle memory of both folders
# in turns. Lines: FOLD-AT <label> <sha>, FOLD-SIZE <label> <file> <bytes|link>, FOLD-TOTAL <label> <bytes>, and
# fold-hosts.py's FOLD-SAMPLE / FOLD-SUMMARY. The whole log also goes to $FAST_CHECKS_OUT/fold-hosts.log.
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet fold-hosts.sh 'cargo build' 'CMUX-570 folded host size and per-process cost'
[ -n "${FAST_CHECKS_OUT:-}" ] && exec > >(tee -a "$FAST_CHECKS_OUT/fold-hosts.log") 2>&1
base="${1:-}"
rounds="${FOLD_ROUNDS:-15}"
scratch="$(mktemp -d)"
trees=()
cleanup() {
  for tree in "${trees[@]}"; do git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1; done
  rm -rf "$scratch"
}
trap cleanup EXIT
# A bare runner: the pinned Rust and Zig and the native build tools (as tui-idle-ram.sh).
command -v cargo >/dev/null || (cd "$root" && ./scripts/install-rust-ci.sh)
if ! command -v zig >/dev/null && [ -z "${ZIG:-}${CMUX_ZIG:-}" ]; then
  zig_env="$(mktemp)"
  (cd "$root" && [ -f ghostty-next/build.zig.zon ] || git submodule update --init --depth 1 ghostty-next)
  (cd "$root" && GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh)
  zig_line="$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true)"
  rm -f "$zig_env"
  [ -z "$zig_line" ] || export "$zig_line"
fi
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
head_sha="$(git -C "$root" rev-parse HEAD)"
if [[ -z "$base" ]]; then
  git -C "$root" fetch -q --no-tags --no-recurse-submodules --shallow-since="14 days ago" origin feat-cmux-next 2>/dev/null \
    || git -C "$root" fetch -q --no-tags --no-recurse-submodules origin feat-cmux-next
  [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && git -C "$root" fetch -q --deepen=200 origin "$head_sha" 2>/dev/null
  base="$(git -C "$root" merge-base HEAD FETCH_HEAD)" || { echo "FOLD-ERROR no merge base with origin/feat-cmux-next"; exit 1; }
else
  base="$(git -C "$root" rev-parse -q --verify "$base^{commit}" 2>/dev/null)" \
    || { git -C "$root" fetch -q --no-tags --no-recurse-submodules --depth=1 origin "$1" && base="$(git -C "$root" rev-parse "$1^{commit}")"; } \
    || { echo "FOLD-ERROR $1 is not a commit here or on origin"; exit 1; }
fi
status=0
for label in base head; do
  if [[ "$label" == head ]]; then tree="$root"; sha="$head_sha"; else
    sha="$base"; tree="$scratch/base"
    git -C "$root" worktree add -q --detach "$tree" "$sha" && trees+=("$tree") || { echo "FOLD-ERROR worktree $sha"; exit 1; }
  fi
  [ -f "$tree/ghostty-next/build.zig" ] || git -C "$tree" submodule update -q --init --depth 1 ghostty-next || { status=1; continue; }
  echo "FOLD-AT $label $sha $(git -C "$root" log -1 --format=%s "$sha" | cut -c1-80)"
  target="$scratch/target-$label"
  bin="$scratch/bin-$label"
  mkdir -p "$bin"
  t0=$(date +%s)
  commit="$(git -C "$tree" rev-parse HEAD)"
  # The macOS bin/cmux carries the iPhone host; on Linux a tree that folds it does so only with this feature.
  tui_features=()
  grep -q '^fold-mobile-host = ' "$tree/cmux-tui/crates/cmux-tui/Cargo.toml" && tui_features=(--features fold-mobile-host)
  (cd "$tree/cmux-tui" && CMUX_TUI_BUILD_COMMIT="$commit" CARGO_TARGET_DIR="$target/tui" \
    cargo build --locked --release -p cmux-tui --bin cmux-tui --bin cmux-tui-host "${tui_features[@]}" 2>&1 | tail -n 2) || { status=1; continue; }
  # The app's own iPhone host, with build-mobile-host.sh's size profile.
  (cd "$tree/cmux-next-ios/rust" && CARGO_PROFILE_RELEASE_LTO=fat CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_PANIC=abort CARGO_TARGET_DIR="$target/mobile" \
    cargo build --locked --release -p cmux-mobile-host --bin cmux-mobile-host 2>&1 | tail -n 1) || { status=1; continue; }
  (cd "$tree/cmux-tui/bindings/examples/rust-agent-screen-detection" && CARGO_TARGET_DIR="$target/detector" \
    cargo build --locked --release 2>&1 | tail -n 1) || { status=1; continue; }
  (cd "$tree/first-party-apps/cloud/server" && CARGO_TARGET_DIR="$target/cloud" \
    cargo build --locked --release --bin cmux-cloud 2>&1 | tail -n 1) || { status=1; continue; }
  echo "FOLD-BUILD $label $(( $(date +%s) - t0 )) s"
  install -m 755 "$target/tui/release/cmux-tui" "$bin/cmux"
  install -m 755 "$target/tui/release/cmux-tui-host" "$bin/cmux-tui-host"
  install -m 755 "$target/detector/release/cmux-agent-screen-detection" "$bin/cmux-agent-screen-detection"
  install -m 755 "$target/cloud/release/cmux-cloud" "$bin/cmux-cloud"
  install -m 755 "$target/mobile/release/cmux-mobile-host" "$bin/cmux-mobile-host"
  for file in "$bin"/*; do strip --strip-unneeded "$file"; done
  # The names this commit's cmux runs by argv[0] become links, as in the bundle (only those built here).
  folded=()
  while IFS= read -r name; do
    [[ -e "$bin/$name" ]] && folded+=("$name")
  done < <("$root/scripts/cmux-next/link-folded-hosts.sh" --list "$bin/cmux")
  (( ${#folded[@]} )) && "$root/scripts/cmux-next/link-folded-hosts.sh" "$bin" "${folded[@]}" | sed "s/^/FOLD-LINK $label /"
  total=0
  for file in "$bin"/*; do
    if [[ -L "$file" ]]; then echo "FOLD-SIZE $label $(basename "$file") link"; continue; fi
    bytes=$(stat -c %s "$file")
    total=$(( total + bytes ))
    echo "FOLD-SIZE $label $(basename "$file") $bytes"
  done
  echo "FOLD-TOTAL $label $total"
done
(( status == 0 )) || exit "$status"
# The fake backend (cmux-mobile-link's testing support) the iPhone host registers with: one build, for both sides;
# it is not what is measured.
(cd "$root/cmux-next-ios/rust" && CARGO_TARGET_DIR="$scratch/target-fake" \
  cargo build --locked --release -p cmux-mobile-host --features fake-backend --bin cmux-mobile-fake-backend 2>&1 | tail -n 1) \
  || { echo "FOLD-ERROR fake backend build"; exit 1; }
python3 "$root/scripts/measure/fold-hosts.py" --bin "base=$scratch/bin-base" --bin "head=$scratch/bin-head" \
  --fake-backend "$scratch/target-fake/release/cmux-mobile-fake-backend" --rounds "$rounds" || exit 1
