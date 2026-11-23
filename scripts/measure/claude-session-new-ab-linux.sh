#!/usr/bin/env bash
# Interleaved A/B of a cold Claude `session/new` through the acpmux daemon on Linux: the start step a Cloud
# chat's first reply waits on (cmux goal cloud-instant-start; production probes: median 1255 ms, tail 4 to 6.5 s).
# Arm A is BASE's acpmux, arm B is HEAD's; each runs its own daemon in its own home, and one client
# (claude-session-new-client.py) times `initialize` and `session/new` for a fresh folder, the arms taking turns.
#   cmux-ci test --setup rust -- 'scripts/measure/claude-session-new-ab-linux.sh base=origin/feat-cmux-next rounds=8'
# Arguments: base=REF (default origin/feat-cmux-next), rounds=N (8). Needs Claude Code (`claude`) on PATH or
# node/npm to install it into the run's folder. Prints one line per start, then per arm the median, min and max of
# session_new_ms, and a JSON object of the same on its own line (AB-SUMMARY).
set -euo pipefail
base=origin/feat-cmux-next
rounds=8
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    *) echo "claude-session-new-ab: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
full_tree() { [[ "$(git -C "$1" config --bool core.sparseCheckout)" != true ]] || git -C "$1" sparse-checkout disable; }
full_tree "$root"
# A short root: each daemon's socket sits under it and a Unix socket path stops at 108 bytes.
out="$(mktemp -d /tmp/csn.XXXXXX)"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  git -C "$root" worktree remove --force "$out/base-src" >/dev/null 2>&1 || true
  rm -rf "$out"
}
trap cleanup EXIT
if ! command -v claude >/dev/null; then
  npm install -g -s --prefix "$out/npm" @anthropic-ai/claude-code >/dev/null
  export PATH="$out/npm/bin:$PATH"
fi
echo "claude-session-new-ab: $(claude --version)"
git fetch -q --depth=50 origin "${base#origin/}" 2>/dev/null || true
base_sha="$(git rev-parse "$base")"
echo "claude-session-new-ab: A=$base ($base_sha) B=HEAD ($(git rev-parse HEAD))"
cd "$root/cmux-tui"
target="${CARGO_TARGET_DIR:-$root/cmux-tui/target}"
cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -n 1
cp "$target/release/acpmux" "$out/acpmux-B"
git -C "$root" worktree add -q --detach "$out/base-src" "$base_sha"
full_tree "$out/base-src"
(cd "$out/base-src/cmux-tui" && CARGO_TARGET_DIR="$target" cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -n 1)
cp "$target/release/acpmux" "$out/acpmux-A"
cmp -s "$out/acpmux-A" "$out/acpmux-B" && echo "claude-session-new-ab: A and B are the same binary (an A/A run)"
client="$root/scripts/measure/claude-session-new-client.py"
for arm in A B; do
  # 0700 whatever the umask: the daemon refuses a group-writable ancestor of its home.
  mkdir -p -m 700 "$out/$arm" "$out/$arm/home" "$out/$arm/work"
  (unset $(env | grep -o -E '^(ACPMUX|CMUX)[A-Z_]*' | tr '\n' ' ') 2>/dev/null || true
   ACPMUX_HOME="$out/$arm/home" ACPMUX_SOCKET="$out/$arm/s.sock" exec "$out/acpmux-$arm" daemon run \
     >"$out/$arm/daemon.log" 2>&1) &
  pids+=($!)
done
for arm in A B; do
  for _ in $(seq 100); do [[ -S "$out/$arm/s.sock" ]] && break; sleep 0.1; done
  [[ -S "$out/$arm/s.sock" ]] || { echo "claude-session-new-ab: daemon $arm did not bind"; tail -n 20 "$out/$arm/daemon.log"; exit 1; }
done
# One warm-up start per arm (Claude Code's first run on a host writes its config), not counted.
for arm in A B; do ACPMUX_SOCKET="$out/$arm/s.sock" python3 -I "$client" "$out/$arm/work/warm" "$arm" >/dev/null || true; done
: >"$out/rows.jsonl"
for ((r = 0; r < rounds; r++)); do
  if ((r % 2 == 0)); then order="A B"; else order="B A"; fi
  for arm in $order; do
    ACPMUX_SOCKET="$out/$arm/s.sock" timeout 60 python3 -I "$client" "$out/$arm/work/r$r" "$arm" | tee -a "$out/rows.jsonl"
  done
done
python3 -I - "$out/rows.jsonl" <<'PY'
import json, statistics, sys
arms = {}
for line in open(sys.argv[1]):
    row = json.loads(line)
    if row.get("ok"):
        arms.setdefault(row["arm"], []).append(row["session_new_ms"])
summary = {a: {"n": len(v), "median": statistics.median(v), "min": min(v), "max": max(v)} for a, v in sorted(arms.items())}
for a, s in summary.items():
    print(f"claude-session-new-ab: arm {a} session_new_ms median {s['median']} min {s['min']} max {s['max']} (n={s['n']})")
print("AB-SUMMARY " + json.dumps(summary))
PY
