#!/usr/bin/env bash
# PTYs held by workspaces nobody has shown (a913 follow-up): cmux-tui/scripts/bench-unshown-ptys.py
# on a headless cmux-tui of this commit and, with against=SHA, of that commit first.
# Run alone on a worker (the PTY count is machine-wide):
#   cmux-ci run --class exclusive --measurement --script scripts/measure/unshown-ptys.sh --ref SHA
#     [--arg=against=SHA] [--arg=count=N]
# Output: PTYS lines (PTYs held after each step) and JSON under .build/unshown-ptys.
set -euo pipefail
against=""
count=50
for arg in "$@"; do
  case "$arg" in
    against=*) against="${arg#against=}" ;;
    count=*) count="${arg#count=}" ;;
    *) echo "unshown-ptys.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
case "$count" in [1-9]|[1-9][0-9]|[1-2][0-9][0-9]) ;; *) echo "unshown-ptys.sh: count must be 1-299" >&2; exit 2 ;; esac
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/unshown-ptys"
rm -rf "$work"
mkdir -p "$work"
echo "PTYS-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) macos=$(sw_vers -productVersion) ptmx_max=$(sysctl -n kern.tty.ptmx_max) rev=$(git rev-parse HEAD)"

binary() { # label revision
  local key sum base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"
  key="$(python3 scripts/ci/cmux_tui_tree_key.py "$2")"
  if curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin" -o "$work/bin-$1"; then
    sum="$(curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
    [ "$(shasum -a 256 "$work/bin-$1" | awk '{print $1}')" = "$sum" ] || { echo "PTYS sha256 mismatch for $1 ($key)" >&2; exit 1; }
    echo "PTYS-BIN $1 rev=$2 published key=$key"
  else
    echo "PTYS-BIN $1 rev=$2 key=$key not published; building it"
    local src="$work/src-$1"
    git worktree add --detach "$src" "$2" >/dev/null
    (cd "$src" && export CI=1 && git submodule update --init --depth 1 ghostty-next >/dev/null \
      && cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-tui)
    cp "$work/target/release/cmux-tui" "$work/bin-$1"
    git worktree remove --force "$src"
  fi
  chmod +x "$work/bin-$1"
}

ulimit -n "$(ulimit -Hn)" 2>/dev/null || ulimit -n 65536 2>/dev/null || true
if [ -n "$against" ]; then
  git cat-file -e "$against^{commit}" 2>/dev/null || git fetch --quiet origin "$against"
  binary against "$against"
fi
binary ref HEAD
state_root="$(mktemp -d /private/tmp/upty.XXXXXX)"
trap 'rm -rf "$state_root"' EXIT
status=0
for label in against ref; do
  [ -x "$work/bin-$label" ] || continue
  python3 -I cmux-tui/scripts/bench-unshown-ptys.py --bin "$work/bin-$label" --count "$count" \
    --label "$label" --root-dir "$state_root" --out "$work/$label.json" || status=$?
done
exit "$status"
