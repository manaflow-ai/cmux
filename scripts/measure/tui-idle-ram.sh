#!/usr/bin/env bash
# The idle cmux-tui daemon's memory on Linux at one or more commits, from one harness on one runner (CMUX-571,
# goal ram-baseline): scripts/measure/tui-idle-ram.py on a release build of each commit's daemon, and with dhat=1
# also a dhat-heap build's heap at exit by allocation site (scripts/measure/dhat-top.py). Run at a pushed head:
#   cmux-ci test -- bash -c 'scripts/measure/tui-idle-ram.sh [dhat=1] [workspaces=1] [settle=20] [profile=release] [SHA...]; echo rc=$?'
# No SHA measures this checkout. Each SHA is checked out into a scratch worktree; this checkout's tui-idle-ram.py
# and dhat-top.py measure every one. Prints "TUI-IDLE-AT <sha>" before each commit's lines.
set -uo pipefail
dhat=0
workspaces=1
settle=20
profile=release
shas=()
for arg in "$@"; do
  case "$arg" in
    dhat=*) dhat="${arg#dhat=}" ;;
    workspaces=*) workspaces="${arg#workspaces=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    profile=*) profile="${arg#profile=}" ;;
    *) shas+=("$arg") ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
here="$root/scripts/measure"
scratch="$(mktemp -d)"
trees=()
cleanup() {
  for tree in "${trees[@]}"; do git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1; done
  rm -rf "$scratch"
}
trap cleanup EXIT
# A bare runner: the pinned Rust and Zig and the native build tools (as infinite-items-linux.sh).
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
# One target directory per build kind across commits: the dependencies build once.
export CARGO_TARGET_DIR_RELEASE="$scratch/target-release" CARGO_TARGET_DIR_DHAT="$scratch/target-dhat"
depth=()
[[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
[[ ${#shas[@]} -eq 0 ]] && shas=(HEAD)
status=0
for sha in "${shas[@]}"; do
  if [[ "$sha" == HEAD ]]; then
    tree="$root"
    full="$(git -C "$root" rev-parse HEAD)"
  else
    git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$root" fetch -q --no-tags --no-recurse-submodules "${depth[@]}" origin "$sha"
    full="$(git -C "$root" rev-parse "$sha^{commit}")"
    tree="$scratch/${full:0:12}"
    git -C "$root" worktree add -q --detach "$tree" "$full" && trees+=("$tree") || { status=1; continue; }
  fi
  [ -f "$tree/ghostty-next/build.zig" ] || git -C "$tree" submodule update -q --init --depth 1 ghostty-next || { status=1; continue; }
  echo "TUI-IDLE-AT $full $(git -C "$root" log -1 --format=%s "$full" 2>/dev/null | cut -c1-80)"
  bins=(--bin cmux-tui)
  grep -q '^name = "cmux-tui-host"' "$tree/cmux-tui/crates/cmux-tui/Cargo.toml" && bins+=(--bin cmux-tui-host)
  t0=$(date +%s)
  (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$CARGO_TARGET_DIR_RELEASE" cargo build --locked --profile "$profile" -p cmux-tui "${bins[@]}" 2>&1 | tail -n 2) || { status=1; continue; }
  out="$CARGO_TARGET_DIR_RELEASE/$profile"
  echo "TUI-IDLE-BUILD ${full:0:12} $(( $(date +%s) - t0 )) s; cmux-tui $(stat -c %s "$out/cmux-tui") bytes"
  command -v size >/dev/null && size -A "$out/cmux-tui" | grep -E '^\.(text|rodata|data|data\.rel\.ro|bss|got|tbss|tdata) ' | sed "s/^/TUI-IDLE-SECTION ${full:0:12} /"
  for run in 1 2 3; do
    python3 "$here/tui-idle-ram.py" --tui "$out/cmux-tui" --workspaces "$workspaces" --settle "$settle" --label "${full:0:12}-r$run" || status=1
  done
  if [[ "$dhat" == 1 ]]; then
    (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$CARGO_TARGET_DIR_DHAT" cargo build --locked --profile "$profile" -p cmux-tui "${bins[@]}" --features dhat-heap 2>&1 | tail -n 2) || { status=1; continue; }
    prof="$scratch/dhat-${full:0:12}.json"
    CMUX_TUI_DHAT_OUT="$prof" python3 "$here/tui-idle-ram.py" --tui "$CARGO_TARGET_DIR_DHAT/$profile/cmux-tui" \
      --workspaces "$workspaces" --settle "$settle" --label "${full:0:12}-dhat" || status=1
    if [ -f "$prof" ]; then python3 "$here/dhat-top.py" "$prof" 40 | sed "s/^/${full:0:12} /"; else echo "DHAT none: ${full:0:12}"; fi
    [ -n "${FAST_CHECKS_OUT:-}" ] && [ -f "$prof" ] && cp "$prof" "$FAST_CHECKS_OUT/"
  fi
done
exit "$status"
