#!/usr/bin/env bash
# Tab, pane, split and workspace create/close latency (perf-10x lifecycle area).
# Run alone on a worker:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/perf-10x-lifecycle.sh --ref SHA
#     [--arg=part=daemon|swift|all] [--arg=rounds=N] [--arg=against=SHA] [--arg=background=N]
# part=daemon: a headless cmux-tui (cmux-tui/scripts/bench-lifecycle.py) times new-tab,
#   new-browser-tab, split right/down, new-workspace and their closes from send to reply.
#   The binary is the commit's published cmux-tui tree, or a release build when unpublished.
#   against=SHA runs that commit's binary first, interleaved round by round.
#   background=N (default 50) adds N idle one-terminal workspaces first, so a cost
#   that grows with the session shows.
# part=swift: the LifecycleBench Swift Testing suite (model + layout, no app).
# part=create: scripts/measure/new-terminal-100x.sh (new terminal: send to reply and to shell
#   exec, span marks, host cost per terminal); it takes rounds=, against= and max_p50_ms=.
# part=panes: the PaneMotionBench Swift Testing suite (split right and down, close, New Column,
#   zoom at 2, 8 and 30 panes, stub content; PANE-BENCH lines, red over its frame budget).
# Output: LIFECYCLE lines (p50/p95/max ms) and JSON under .build/perf-lifecycle.
set -euo pipefail
if [ "${1:-}" = part=panes ]; then
  cd "$(git rev-parse --show-toplevel)"
  CMUX_PANE_BENCH=1 exec ./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext PaneMotionBench
fi
if [ "${1:-}" = part=create ]; then
  shift
  exec "$(git rev-parse --show-toplevel)/scripts/measure/new-terminal-100x.sh" "$@"
fi
part=all
rounds=40
against=""
background=50
for arg in "$@"; do
  case "$arg" in
    part=daemon|part=swift|part=all) part="${arg#part=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    against=*) against="${arg#against=}" ;;
    background=*) background="${arg#background=}" ;;
    *) echo "perf-10x-lifecycle.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
case "$background" in [0-9]|[1-9][0-9]|[1-2][0-9][0-9]) ;; *) echo "perf-10x-lifecycle.sh: background must be 0-299" >&2; exit 2 ;; esac
case "$rounds" in [1-9]|[1-9][0-9]|[1-2][0-9][0-9]) ;; *) echo "perf-10x-lifecycle.sh: rounds must be 1-299" >&2; exit 2 ;; esac
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/perf-lifecycle"
rm -rf "$work"
mkdir -p "$work"
echo "LIFECYCLE-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cpu=\"$(sysctl -n machdep.cpu.brand_string)\" cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) rev=$(git rev-parse HEAD)"
echo "LIFECYCLE-LOAD before $(uptime | sed 's/.*load averages*: //')"
status=0

binary() { # label revision
  local key sum base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"
  key="$(python3 scripts/ci/cmux_tui_tree_key.py "$2")"
  if curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin" -o "$work/bin-$1"; then
    sum="$(curl -fsSL --proto '=https' "$base/tree/$key/cmux-tui-aarch64-apple-darwin.sha256" | awk '{print $1}')"
    [ "$(shasum -a 256 "$work/bin-$1" | awk '{print $1}')" = "$sum" ] || { echo "LIFECYCLE sha256 mismatch for $1 ($key)" >&2; exit 1; }
    echo "LIFECYCLE-BIN $1 rev=$2 published key=$key"
  else
    echo "LIFECYCLE-BIN $1 rev=$2 key=$key not published; building it"
    local src="$work/src-$1"
    git worktree add --detach "$src" "$2" >/dev/null
    (cd "$src" && export CI=1 && git submodule update --init --depth 1 ghostty-next >/dev/null \
      && cd cmux-tui && CARGO_TARGET_DIR="$work/target" cargo build --release --locked -p cmux-tui)
    cp "$work/target/release/cmux-tui" "$work/bin-$1"
    git worktree remove --force "$src"
  fi
  chmod +x "$work/bin-$1"
}

if [ "$part" = daemon ] || [ "$part" = all ]; then
  ulimit -n "$(ulimit -Hn)" 2>/dev/null || ulimit -n 65536 2>/dev/null || true
  if [ -n "$against" ]; then
    git cat-file -e "$against^{commit}" 2>/dev/null || git fetch --quiet origin "$against"
    binary against "$against"
  fi
  binary ref HEAD
  state_root="$(mktemp -d /private/tmp/lcab.XXXXXX)"
  trap 'rm -rf "$state_root"' EXIT
  # Interleave: each pass runs a quarter of the rounds per binary, so drift on
  # the worker hits both sides alike.
  passes=4
  per=$(( (rounds + passes - 1) / passes ))
  for pass in $(seq 1 "$passes"); do
    for label in against ref; do
      [ -x "$work/bin-$label" ] || continue
      python3 -I cmux-tui/scripts/bench-lifecycle.py --bin "$work/bin-$label" --rounds "$per" --background "$background" \
        --label "$label-p$pass" --root-dir "$state_root" --spans --out "$work/$label-p$pass.json" || status=$?
    done
  done
  python3 -I - "$work" <<'PY' || status=$?
import glob, json, os, sys
work = sys.argv[1]
for label in ("against", "ref"):
    merged = {}
    for path in sorted(glob.glob(os.path.join(work, f"{label}-p*.json"))):
        for op, d in json.load(open(path))["ops"].items():
            merged.setdefault(op, []).extend(d["samples_ms"])
    for op, s in merged.items():
        s.sort()
        q = lambda p: s[min(len(s) - 1, int(p * len(s)))]
        print(f'LIFECYCLE-DAEMON {label} op="{op}" n={len(s)} p50={q(0.5):.2f} p95={q(0.95):.2f} max={s[-1]:.2f}')
PY
fi

if [ "$part" = swift ] || [ "$part" = all ]; then
  CMUX_LIFECYCLE_BENCH=1 CMUX_LIFECYCLE_BENCH_ROUNDS="$rounds" \
    ./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext LifecycleBench || status=$?
fi
echo "LIFECYCLE-LOAD after $(uptime | sed 's/.*load averages*: //')"
exit "$status"
