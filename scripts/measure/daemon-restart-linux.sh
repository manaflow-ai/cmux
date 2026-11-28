#!/usr/bin/env bash
# The daemon's restart to a non-empty chat attach on Linux (goal restart-to-chat's daemon half, 178 ms from
# cmux#42296): cmux-tui/crates/acpmux/tests/god_daemon.rs god_and_small_homes_in_one_harness, run up to three times
# in a time budget; each home's GOD-BASELINE restartChatAttachMs (SIGTERM through the relaunched daemon's
# selected-chat attach), the median over the runs. Run at a pushed head:
#   cmux-ci test --setup rust -- 'scripts/measure/daemon-restart-linux.sh [runs=3] [budget=900]'
#   daemon-restart-linux.sh build-only: only the release test build (the perf cron builds under a cap of its own).
# A run starts only while the runs so far, plus the longest of them, fit in budget seconds, and each run is cut at
# what is left of it. A run whose harness assert fails (restart over 2 s, a settled step) still gives the homes it
# printed: a slow restart is the reading, not a missing one.
# Prints each run's GOD-BASELINE summary, then the rows as one JSON object ({"rows": [...]}) on a line of its own: the
# report perf-cron.py's Linux part reads (its rows are webui.daemon_restart.<shape>_home.chat_attach_ms).
set -euo pipefail
runs=3
budget=900
build_only=0
for arg in "$@"; do
  case "$arg" in
    runs=*) runs="${arg#runs=}" ;;
    budget=*) budget="${arg#budget=}" ;;
    build-only) build_only=1 ;;
    *) echo "daemon-restart-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
# A bare runner (the perf cron's Linux part): the pinned Rust and the native build tools.
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
cd "$root/cmux-tui"
cargo test --locked --release -p acpmux --test god_daemon --no-run 2>&1 | tail -n 3
[[ "$build_only" == 1 ]] && exit 0
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
start=$SECONDS
longest=0
for ((i = 1; i <= runs; i++)); do
  used=$((SECONDS - start))
  if ((i > 1 && used + longest > budget)); then
    echo "daemon-restart: run $i not started: $used s used, the longest run took $longest s, budget $budget s"
    break
  fi
  left=$((budget - used))
  ((left < 60)) && left=60
  began=$SECONDS
  code=0
  # Each run's homes (about 2 GB for god) under a temp dir of its own, removed after the run however it ended.
  mkdir -p "$out/tmp$i"
  TMPDIR="$out/tmp$i" timeout --kill-after=30 "$left" cargo test --locked --release -p acpmux --test god_daemon -- \
    --ignored --nocapture --exact god_and_small_homes_in_one_harness >"$out/run$i.log" 2>&1 || code=$?
  rm -rf "$out/tmp$i"
  took=$((SECONDS - began))
  ((took > longest)) && longest=$took
  if ((code == 124 || code == 137)); then
    echo "daemon-restart: run $i cut at $took s: its share was the $left s left of the $budget s budget"
  else
    echo "daemon-restart: run $i exit $code in $took s"
  fi
  if ((code != 0)); then
    grep -E "panicked|exceeded|failed|daemon exited by itself" "$out/run$i.log" | head -n 6 || true
    # Why the daemon went away ("the daemon closed the socket"): the harness prints the daemon log's last 16 KB on a
    # failure; keep its error, panic and signal lines and the last few lines, so the perf cron's tail says why.
    awk '/^daemon log .* \(last [0-9]+ bytes\):/{keep=1; n=0} keep{buf[n++]=$0} END{
      for (j = 0; j < n; j++) if (buf[j] ~ /ERROR|WARN|panic|signal|abort|killed|oom|exit/) print "daemon-restart: log: " substr(buf[j], 1, 300)
      for (j = (n > 8 ? n - 8 : 0); j < n; j++) print "daemon-restart: log tail: " substr(buf[j], 1, 300)
    }' "$out/run$i.log" | tail -n 20 || true
  fi
done
python3 - "$out" <<'PY'
import glob, json, os, statistics, sys

per = {}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "run*.log"))):
    for line in open(path, errors="replace"):
        if not line.startswith("GOD-BASELINE "):
            continue
        try:
            rec = json.loads(line.split(" ", 1)[1])
        except ValueError:
            continue
        ms = rec.get("restartChatAttachMs")
        if isinstance(rec.get("shape"), str) and isinstance(ms, (int, float)) and not isinstance(ms, bool):
            per.setdefault(rec["shape"], []).append(float(ms))
            print(f"daemon-restart: {os.path.basename(path)} {rec['shape']} restartChatAttachMs {ms} "
                  f"shutdownMs {rec.get('shutdownMs')}")
# The harness runs the small home, then the god home: a run cut in the god home, or a small home that failed its
# assert, leaves small rows only. The worst-of row would then read the small home as the whole number, so no god
# reading means no metric at all.
if "god" not in per:
    print("daemon-restart: no god home reading (a run cut or failed before it); no metric")
    print(json.dumps({"rows": []}))
    sys.exit(1)
rows = []
for shape, values in sorted(per.items()):
    med = statistics.median(values)
    # The floor a change must clear: the runs' own spread, at least 10 % of the median and 5 ms.
    floor = max(round(0.1 * med, 1), max(values) - min(values), 5.0)
    rows.append({"name": f"daemon_restart.{shape}_home.chat_attach_ms", "p50": med, "p95": med, "unit": "ms",
                 "floor": floor, "version": 1, "runs": len(values), "values": values})
print(json.dumps({"rows": rows}))
sys.exit(0 if rows else 1)
PY
