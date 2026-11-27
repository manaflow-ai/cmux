#!/usr/bin/env bash
# Interleaved A/B (and A/A) of the acpmux daemon's restart to a selected chat's attach on Linux: the daemon half of
# startup row (c) "quit and relaunch to chat" (docs/perf/auto-research-targets.md in cmuxterm-hq).
# One test binary (god_daemon.rs god_and_small_homes_in_one_harness, built at HEAD) drives every run; only the daemon
# it starts changes, through ACPMUX_GOD_DAEMON_BIN: arm A is BASE's acpmux, arm B is HEAD's, arm A2 is a second copy
# of BASE's (the A/A noise arm). The arms run round-robin, rotated each round, so drift on the host lands on all.
#   cmux-ci test --setup rust -- 'scripts/measure/daemon-restart-ab-linux.sh base=origin/feat-cmux-next rounds=3'
# Arguments: base=REF (default origin/feat-cmux-next), rounds=N (3), shapes=god|small|small,god (god),
# budget=SECONDS for the runs after the builds (2400).
# Prints one line per run, then per arm and shape the median and spread of restartChatAttachMs, shutdownMs, readyMs,
# firstListMs, allLogsMs and each startup phase, and a JSON object of the same on its own line (AB-SUMMARY).
set -euo pipefail
base=origin/feat-cmux-next
rounds=3
shapes=god
budget=2400
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    shapes=*) shapes="${arg#shapes=}" ;;
    budget=*) budget="${arg#budget=}" ;;
    *) echo "daemon-restart-ab: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
# A sparse checkout (a lane VM's `wt new` has only cmux-tui/ and a few folders) cannot build: the
# crates read files across the repository (include_str!) and cmux-vm's crate. Check out the whole tree.
full_tree() { [[ "$(git -C "$1" config --bool core.sparseCheckout)" != true ]] || git -C "$1" sparse-checkout disable; }
full_tree "$root"
# A short root: the daemon socket sits several levels under $out/tmp and a Unix socket path stops at
# 108 bytes (an inherited $TMPDIR under /tmp/acpmux-UID/t/... made every arm fail "did not bind its socket").
out="$(mktemp -d /tmp/dab.XXXXXX)"
trap 'git -C "$root" worktree remove --force "$out/base-src" >/dev/null 2>&1 || true; rm -rf "$out"' EXIT
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=50)
git fetch --no-recurse-submodules -q ${depth[@]+"${depth[@]}"} origin "${base#origin/}" 2>/dev/null || true
base_sha="$(git rev-parse "$base")"
head_sha="$(git rev-parse HEAD)"
echo "daemon-restart-ab: A=$base ($base_sha) B=HEAD ($head_sha)"
# HEAD: the test binary and the daemon.
cd "$root/cmux-tui"
build_start=$SECONDS
cargo test --locked --release -p acpmux --test god_daemon --no-run 2>&1 | tail -n 2
cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -n 1
target="${CARGO_TARGET_DIR:-$root/cmux-tui/target}"
test_bin="$(ls -t "$target"/release/deps/god_daemon-* | grep -v '\.d$' | head -n 1)"
cp "$target/release/acpmux" "$out/acpmux-B"
cp "$test_bin" "$out/god_daemon"
# BASE: the daemon alone, in the same target folder (registry crates are reused), then HEAD's daemon put back.
git -C "$root" worktree add -q --detach "$out/base-src" "$base_sha"
full_tree "$out/base-src"
(cd "$out/base-src/cmux-tui" && CARGO_TARGET_DIR="$target" cargo build --locked --release -p acpmux --bin acpmux 2>&1 | tail -n 1)
cp "$target/release/acpmux" "$out/acpmux-A"
cp "$out/acpmux-A" "$out/acpmux-A2"
cp "$out/acpmux-B" "$target/release/acpmux"
echo "daemon-restart-ab: builds took $((SECONDS - build_start)) s"
cmp -s "$out/acpmux-A" "$out/acpmux-B" && echo "daemon-restart-ab: A and B are the same binary (an A/A run)"
arms=(A B A2)
start=$SECONDS
longest=0
for ((r = 0; r < rounds; r++)); do
  for ((k = 0; k < ${#arms[@]}; k++)); do
    arm="${arms[$(((k + r) % ${#arms[@]}))]}"
    used=$((SECONDS - start))
    if ((used + longest > budget)); then
      echo "daemon-restart-ab: round $r arm $arm not started: $used s used of $budget"
      break 2
    fi
    began=$SECONDS
    # 0700 whatever the umask: the daemon refuses a group-writable ancestor of its home (a lane VM's umask is 0002).
    mkdir -p -m 700 "$out/tmp"
    code=0
    (cd "$root/cmux-tui/crates/acpmux" && TMPDIR="$out/tmp" ACPMUX_GOD_SHAPES="$shapes" \
      ACPMUX_GOD_DAEMON_BIN="$out/acpmux-$arm" timeout --kill-after=30 900 "$out/god_daemon" \
      --ignored --nocapture --exact god_and_small_homes_in_one_harness >"$out/run-$r-$arm.log" 2>&1) || code=$?
    rm -rf "$out/tmp"
    took=$((SECONDS - began))
    ((took > longest)) && longest=$took
    echo "daemon-restart-ab: round $r arm $arm exit $code in $took s"
    ((code != 0)) && { grep -E "panicked|exceeded|failed" "$out/run-$r-$arm.log" | head -n 5 || true; }
  done
done
python3 - "$out" <<'PY'
import glob, json, os, re, statistics, sys

keys = ["restartChatAttachMs", "shutdownMs", "readyMs", "firstListMs", "allLogsMs"]
data = {}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "run-*.log"))):
    arm = re.match(r"run-\d+-(\w+)\.log", os.path.basename(path)).group(1)
    for line in open(path, errors="replace"):
        if not line.startswith("GOD-BASELINE "):
            continue
        try:
            rec = json.loads(line.split(" ", 1)[1])
        except ValueError:
            continue
        row = {k: rec.get(k) for k in keys}
        for name, ms in (rec.get("startupPhasesMs") or {}).items():
            row["phase:" + name] = ms
        for name, ms in (rec.get("marksMs") or {}).items():
            row["mark:" + name] = ms
        cell = data.setdefault(rec.get("shape"), {}).setdefault(arm, [])
        cell.append(row)
        print(f"run {os.path.basename(path)} {rec.get('shape')}: " + " ".join(f"{k}={row[k]}" for k in keys))

def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None

summary = {}
for shape, arms in data.items():
    names = sorted({k for rows in arms.values() for row in rows for k in row}, key=lambda k: (k.find(":"), k))
    for arm, rows in sorted(arms.items()):
        for k in names:
            vals = [num(r.get(k)) for r in rows]
            vals = [v for v in vals if v is not None]
            if vals:
                summary.setdefault(shape, {}).setdefault(k, {})[arm] = {
                    "median": statistics.median(vals), "min": min(vals), "max": max(vals), "n": len(vals)}
    print(f"\n{shape} home: median (min-max, n) per arm")
    for k, per in summary.get(shape, {}).items():
        cells = "  ".join(f"{a}={v['median']:g} ({v['min']:g}-{v['max']:g}, {v['n']})" for a, v in sorted(per.items()))
        print(f"  {k:34} {cells}")
print("AB-SUMMARY " + json.dumps(summary, sort_keys=True))
PY
