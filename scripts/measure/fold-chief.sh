#!/usr/bin/env bash
# CMUX-570 (Leo: "decreasing bundle size"): what folding the Home Chief (bin/optchat-chief) into the multicall
# bin/cmux saves in bytes and costs per Chief process, from one harness on one Linux runner, one tree:
#   base  the bundle as it ships without the fold: bin/cmux (cmux-tui's release profile, no Chief) and its own
#         bin/optchat-chief (its workspace's release profile: fat LTO, one codegen unit, opt-level "s"), as
#         build-optchat-chief.sh builds it.
#   head  bin/cmux built with `fold-optchat-chief` (what the macOS build always carries) and bin/optchat-chief a
#         link to it (link-optchat-chief.sh).
# Both from this checkout, so nothing but the fold differs (a fleet snapshot has no history to build a base commit
# from). Fleet only:
#   cmux-ci test --timeout 7200 --artifact DIR -- bash -c 'set -o pipefail; scripts/measure/fold-chief.sh'
# Each file is stripped (strip --strip-unneeded). Then fold-chief.py samples start time and idle memory of both
# folders in turns. Lines: FOLD-AT <label> <sha>, FOLD-SIZE <label> <file> <bytes|link>, FOLD-TOTAL <label> <bytes>,
# and fold-chief.py's FOLD-SAMPLE / FOLD-SUMMARY (the fold-hosts format). The log also goes to
# $FAST_CHECKS_OUT/fold-chief.log.
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
# The fast-checks fleet runner sets FAST_CHECKS_OUT (and neither variable the guard reads).
[ -n "${FAST_CHECKS_OUT:-}" ] || cmux_next_require_fleet fold-chief.sh 'cargo build' 'CMUX-570 folded Chief size and per-process cost'
[ -n "${FAST_CHECKS_OUT:-}" ] && exec > >(tee -a "$FAST_CHECKS_OUT/fold-chief.log") 2>&1
rounds="${FOLD_ROUNDS:-15}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
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
[ -f "$root/ghostty-next/build.zig" ] || git -C "$root" submodule update -q --init --depth 1 ghostty-next || exit 1
sha="$(git -C "$root" rev-parse HEAD)"
target="$scratch/target"
t0=$(date +%s)
# The Chief on its own, as build-optchat-chief.sh builds it.
(cd "$root/Native/OptChat/optchat-chief" && OPTCHAT_BUILD_COMMIT="${sha:0:11}" CARGO_TARGET_DIR="$target/chief" \
  cargo build --locked --release --bin optchat-chief 2>&1 | tail -n 1) || exit 1
for label in base head; do
  echo "FOLD-AT $label $sha $(git -C "$root" log -1 --format=%s | cut -c1-80)"
  features=()
  [[ "$label" == head ]] && features=(--features fold-optchat-chief)
  (cd "$root/cmux-tui" && CMUX_TUI_BUILD_COMMIT="$sha" CARGO_TARGET_DIR="$target/tui-$label" \
    cargo build --locked --release -p cmux-tui --bin cmux-tui "${features[@]}" 2>&1 | tail -n 2) || exit 1
  echo "FOLD-BUILD $label $(( $(date +%s) - t0 )) s"
  bin="$scratch/bin-$label"
  mkdir -p "$bin"
  install -m 755 "$target/tui-$label/release/cmux-tui" "$bin/cmux"
  install -m 755 "$target/chief/release/optchat-chief" "$bin/optchat-chief"
  for file in "$bin"/*; do strip --strip-unneeded "$file"; done
  "$root/scripts/cmux-next/link-optchat-chief.sh" "$bin" | sed "s/^/FOLD-LINK $label /"
  total=0
  for file in "$bin"/*; do
    if [[ -L "$file" ]]; then echo "FOLD-SIZE $label $(basename "$file") link"; continue; fi
    bytes=$(stat -c %s "$file")
    total=$(( total + bytes ))
    echo "FOLD-SIZE $label $(basename "$file") $bytes"
  done
  echo "FOLD-TOTAL $label $total"
done
# Base must keep its own Chief and head must link it, or the comparison is not the fold.
[[ ! -L "$scratch/bin-base/optchat-chief" && -L "$scratch/bin-head/optchat-chief" ]] \
  || { echo "FOLD-ERROR expected base to keep bin/optchat-chief and head to link it"; exit 1; }
python3 "$root/scripts/measure/fold-chief.py" --bin "base=$scratch/bin-base" --bin "head=$scratch/bin-head" \
  --rounds "$rounds" || exit 1
