#!/usr/bin/env bash
# l10n-allow-file: bisect harness, not shipped UI. Deleted before merge (perf #24569 group 3).
# Runs the tip's benches against the pane sources of several commits on one runner, rounds interleaved.
#   SHAS="sha1 sha2" BENCHES="chat-open-god replay-god" ROUNDS=3 PAR=2 bash bench/bisect-g3.sh
# For each sha: git archive of webviews/ at that sha, the tip's bench/ and test/support/ over it, the tip's
# node_modules linked in. Prints "BISECT <sha> <round> PERF_ROW..." lines and a median table at the end.
set -u
ROOT=$(git rev-parse --show-toplevel)
TIP=$ROOT/webviews
WORK=${RUNNER_TEMP:-/tmp}/bisect-g3
OUT=${FAST_CHECKS_OUT:-$WORK/out}
mkdir -p "$WORK" "$OUT/logs"
ROUNDS=${ROUNDS:-3}
PAR=${PAR:-2}
echo "nproc=$(nproc)"
# shellcheck disable=SC2086
git -C "$ROOT" fetch -q --depth=1 --no-tags origin $SHAS || { echo "fetch failed"; exit 2; }
for sha in $SHAS; do
  d=$WORK/$sha
  rm -rf "$d"; mkdir -p "$d"
  git -C "$ROOT" archive "$sha" webviews | tar -x -C "$d"
  rm -rf "$d/webviews/bench" "$d/webviews/test/support"
  cp -a "$TIP/bench" "$d/webviews/bench"
  cp -a "$TIP/test/support" "$d/webviews/test/support"
  ln -s "$TIP/node_modules" "$d/webviews/node_modules"
  for top in Packages Resources cmux-tui config design schemas; do
    [ -e "$ROOT/$top" ] && ln -s "$ROOT/$top" "$d/$top"
  done
done

cmd_for() {
  case "$1" in
    chat-open-god) echo "FIXTURE=god bun bench/chat-open.bench.ts 3 300" ;;
    chat-open) echo "bun bench/chat-open.bench.ts 3 300" ;;
    replay-god) echo "FIXTURE=god bun bench/transcript-replay.bench.ts" ;;
    replay) echo "bun bench/transcript-replay.bench.ts --turns 600" ;;
    update-one) echo "bun bench/update-one.bench.ts --changes 20 --turns 1000" ;;
    activity) echo "bun bench/agent-activity-groups.bench.ts 5 50" ;;
    scroll) echo "bun bench/transcript-scroll-frame.bench.ts 3000 2" ;;
    diff) echo "CMUX_DIFF_BENCH_ITERATIONS=10 CMUX_DIFF_BENCH_RENDER_APP=1 bun bench/diff-stream.bench.ts" ;;
    *) echo "false" ;;
  esac
}

jobs=$WORK/jobs.txt
: >"$jobs"
for r in $(seq 1 "$ROUNDS"); do
  # Rotate the sha order each round so no sha always runs first or last.
  set -- $SHAS
  n=$#
  for i in $(seq 0 $((n - 1))); do
    idx=$(((i + r - 1) % n + 1))
    sha=${!idx}
    for b in $BENCHES; do echo "$r $sha $b" >>"$jobs"; done
  done
done

run_job() {
  r=$1 sha=$2 b=$3
  log=$OUT/logs/${sha:0:11}-$b-r$r.log
  (cd "$WORK/$sha/webviews" && timeout 900 bash -c "$(cmd_for "$b")") >"$log" 2>&1
  code=$?
  grep '^PERF_ROW' "$log" | sed "s/^/BISECT ${sha:0:11} $r $b /"
  if [ "$b" = diff ]; then grep -i 'p95' "$log" | tail -3 | sed "s/^/BISECT ${sha:0:11} $r diff RAW /"; fi
  [ $code -eq 0 ] || { echo "BISECT ${sha:0:11} $r $b EXIT $code"; tail -15 "$log"; }
}
export -f run_job cmd_for
export WORK OUT
xargs -P "$PAR" -L 1 bash -c 'run_job "$@"' _ <"$jobs" | tee "$OUT/bisect.txt"

python3 - "$OUT/bisect.txt" <<'PY'
import json, statistics, sys, collections
vals = collections.defaultdict(list)
order = []
for line in open(sys.argv[1]):
    parts = line.split(" ", 4)
    if len(parts) < 5 or not parts[4].startswith("PERF_ROW"):
        continue
    sha = parts[1]
    if sha not in order:
        order.append(sha)
    try:
        row = json.loads(parts[4].split(" ", 1)[1])
    except Exception:
        continue
    vals[(row["name"], sha)].append(row.get("p95"))
names = sorted({n for n, _ in vals})
print("SUMMARY median p95 over rounds (values)")
for n in names:
    cells = []
    for sha in order:
        v = [x for x in vals.get((n, sha), []) if isinstance(x, (int, float))]
        cells.append(f"{sha[:8]}={statistics.median(v):.3g}{[round(x, 2) for x in v]}" if v else f"{sha[:8]}=-")
    print("SUMMARY", n, " | ".join(cells))
PY
