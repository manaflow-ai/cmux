#!/usr/bin/env bash
# CMUX-570 (Leo: "decreasing bundle size"): what folding the Home Chief (bin/optchat-chief) into the multicall
# bin/cmux saves in bytes and costs per Chief process, base against head, from one harness on one Linux runner.
# Fleet only:
#   cmux-ci test --timeout 7200 --artifact DIR -- bash -c 'set -o pipefail; scripts/measure/fold-chief.sh [BASE_SHA]'
# BASE_SHA defaults to this checkout's merge base with origin/feat-cmux-next. For each commit it builds bin/cmux
# (cmux-tui's release profile; with `fold-optchat-chief` when the commit has it, as the macOS build always does)
# and bin/optchat-chief (its own workspace and release profile: fat LTO, one codegen unit, opt-level "s"), strips
# both (strip --strip-unneeded) and lays them out as the bundle does: a commit whose cmux carries the Chief gets
# bin/optchat-chief as a link to cmux. Then fold-chief.py samples start time and idle memory of both folders in
# turns. Lines: FOLD-AT <label> <sha>, FOLD-SIZE <label> <file> <bytes|link>, FOLD-TOTAL <label> <bytes>, and
# fold-chief.py's FOLD-SAMPLE / FOLD-SUMMARY (the fold-hosts format). The log also goes to
# $FAST_CHECKS_OUT/fold-chief.log.
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
# The fast-checks fleet runner sets FAST_CHECKS_OUT (and neither variable the guard reads).
[ -n "${FAST_CHECKS_OUT:-}" ] || cmux_next_require_fleet fold-chief.sh 'cargo build' 'CMUX-570 folded Chief size and per-process cost'
[ -n "${FAST_CHECKS_OUT:-}" ] && exec > >(tee -a "$FAST_CHECKS_OUT/fold-chief.log") 2>&1
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
  tui_features=()
  folds=0
  grep -q '^fold-optchat-chief = ' "$tree/cmux-tui/crates/cmux-tui/Cargo.toml" && { tui_features=(--features fold-optchat-chief); folds=1; }
  (cd "$tree/cmux-tui" && CMUX_TUI_BUILD_COMMIT="$commit" CARGO_TARGET_DIR="$target/tui" \
    cargo build --locked --release -p cmux-tui --bin cmux-tui "${tui_features[@]}" 2>&1 | tail -n 2) || { status=1; continue; }
  # The standalone Chief, as build-optchat-chief.sh builds it (its workspace's own release profile).
  (cd "$tree/Native/OptChat/optchat-chief" && CARGO_TARGET_DIR="$target/chief" \
    cargo build --locked --release --bin optchat-chief 2>&1 | tail -n 1) || { status=1; continue; }
  echo "FOLD-BUILD $label $(( $(date +%s) - t0 )) s"
  install -m 755 "$target/tui/release/cmux-tui" "$bin/cmux"
  install -m 755 "$target/chief/release/optchat-chief" "$bin/optchat-chief"
  for file in "$bin"/*; do strip --strip-unneeded "$file"; done
  # The standalone head Chief stays beside the folder (not counted) so the per-process table can also compare
  # the same source run both ways.
  if (( folds )); then
    mv "$bin/optchat-chief" "$scratch/optchat-chief-standalone-$label"
    ln -s cmux "$bin/optchat-chief"
    echo "FOLD-LINK $label optchat-chief -> cmux"
  fi
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
python3 "$root/scripts/measure/fold-chief.py" --bin "base=$scratch/bin-base" --bin "head=$scratch/bin-head" \
  --rounds "$rounds" || exit 1
