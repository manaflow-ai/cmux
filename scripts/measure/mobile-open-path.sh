#!/usr/bin/env bash
# The cmux-tui daemon's share of the iPhone open and reconnect path: round trips, bytes and
# daemon-side time to first content at 1x/10x/100x scale (mobile-open-path.py has the details).
# Builds release cmux-tui at this ref and runs the harness against it, headless, on Linux:
#   cmux-ci run --class exclusive --script scripts/measure/mobile-open-path.sh --ref SHA \
#     [--arg=runs=10] [--arg=workspaces=10,100,1000] [--arg=scrollback=1000,10000,100000] \
#     [--arg=scenarios=setup,reattach] [--arg=before=SHA] --timeout 3600 \
#     --artifact .build/mobile-open-path/report.json
# before=SHA: also builds that commit's cmux-tui/ and measures both on this worker, then prints a
# before/after table (artifacts report-before.json and report.json). Exit 1: build, daemon start
# or a daemon error reply failed.
set -euo pipefail
runs=10
workspaces="10,100,1000"
scrollback="1000,10000,100000"
scenarios="setup,reattach"
before=""
for arg in "$@"; do
  case "$arg" in
    runs=*) runs="${arg#runs=}" ;;
    workspaces=*) workspaces="${arg#workspaces=}" ;;
    scrollback=*) scrollback="${arg#scrollback=}" ;;
    scenarios=*) scenarios="${arg#scenarios=}" ;;
    before=*) before="${arg#before=}" ;;
    *) echo "mobile-open-path.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$runs" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "mobile-open-path.sh: runs is 1-999" >&2; exit 2; }
[[ "$workspaces" =~ ^[0-9]+(,[0-9]+)*$ && "$scrollback" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "mobile-open-path.sh: workspaces= and scrollback= are comma lists of numbers" >&2; exit 2; }
[[ "$scenarios" =~ ^(setup|reattach)(,(setup|reattach))?$ ]] || { echo "mobile-open-path.sh: scenarios=setup,reattach" >&2; exit 2; }
[[ -z "$before" || "$before" =~ ^[0-9a-f]{40}$ ]] || { echo "mobile-open-path.sh: before= is a 40-character SHA" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
if [[ -n "$before" ]] && [ -n "$(git status --porcelain --untracked-files=no -- cmux-tui)" ]; then
  echo "mobile-open-path.sh: cmux-tui/ has uncommitted changes; before= swaps it out, so commit or stash them first" >&2
  exit 2
fi
# cmux-tui's terminal engine builds from the ghostty-next submodule, which a fast-checks snapshot leaves empty.
[ -f ghostty-next/build.zig ] || [ -n "${CMUX_GHOSTTY_SRC:-}" ] || git submodule update --init --depth 1 ghostty-next
# A bare runner: the pinned Rust and Zig and the native build tools (as infinite-items-linux.sh).
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
if ! command -v zig >/dev/null && [ -z "${ZIG:-}${CMUX_ZIG:-}" ]; then
  zig_env="$(mktemp)"
  GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh
  zig_line="$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true)"
  rm -f "$zig_env"
  [ -z "$zig_line" ] || export "$zig_line"
fi
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
work="$root/.build/mobile-open-path"
rm -rf "$work"
mkdir -p "$work/after" "$work/before"
target="$(cd cmux-tui && cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
build() {  # build DEST: release cmux-tui (and cmux-tui-host, which the daemon runs its hosts from when it sits beside it)
  (cd "$root/cmux-tui" && cargo build --locked --release -p cmux-tui --bin cmux-tui --bin cmux-tui-host 2>&1 | tail -n 3; exit "${PIPESTATUS[0]}")
  cp "$target/release/cmux-tui" "$1/"
  [ ! -f "$target/release/cmux-tui-host" ] || cp "$target/release/cmux-tui-host" "$1/"
}
measure() {  # measure DIR OUT
  python3 scripts/measure/mobile-open-path.py --binary "$1/cmux-tui" --runs "$runs" --scenarios "$scenarios" \
    --workspaces "$workspaces" --scrollback-lines "$scrollback" --out "$2"
}
build "$work/after"
if [[ -n "$before" ]]; then
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
  fetch_url="$(git remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)"
  git rev-parse --verify -q "$before^{commit}" >/dev/null || git fetch --no-recurse-submodules -q ${depth[@]+"${depth[@]}"} "$fetch_url" "$before"
  trap 'git restore --source=HEAD --staged --worktree -- cmux-tui' EXIT
  git restore --source="$before" --staged --worktree -- cmux-tui
  build "$work/before"
  git restore --source=HEAD --staged --worktree -- cmux-tui
  trap - EXIT
  measure "$work/before" "$work/report-before.json"
fi
measure "$work/after" "$work/report.json"
if [[ -n "$before" ]]; then
  python3 scripts/measure/mobile-open-path.py --compare "$work/report-before.json" "$work/report.json"
fi
