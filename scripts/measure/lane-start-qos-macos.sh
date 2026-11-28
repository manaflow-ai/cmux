#!/usr/bin/env bash
# A lane's start on a Mac at the priority it ran before and after leo-workspace #9927 and #10714, and the
# git-fetch-once throttle, in one harness. Leo, 2026-11-24: "shouldn't these be at high priority so that they can
# start faster?" Run on a fleet Mac:
#   cmux-ci run --class exclusive --os macos --measurement --script scripts/measure/lane-start-qos-macos.sh --ref SHA
#     [--arg N_COLD [--arg N_WARM [--arg SPIN]]]
#   N_COLD  cold starts per arm and load (default 3); N_WARM warm starts (default 5); SPIN duress spinners
#           (default 2 x cores)
#
# A lane start is the git that `wt new` runs: cold, the repo has no mirror (a bare clone of the step's own
# tree, then the worktree and its reads); warm, the mirror exists (a fetch from that checkout, then the
# worktree and its reads). The reads are the six local git calls #9927 counted under the background prefix.
# Arms:
#   before  the whole start under `taskpolicy -b`: an agent's `wt new` inherited the harness's darwin background
#           class (acpmux) and ran its local git at LOW_QOS, until #9927 and #10714
#   after   at normal priority (`wt.normal_qos()` and `foreground_self()`)
# The fetch arms are git-fetch-once's network fetch (a depth-1 fetch of this commit from GitHub):
#   throttle  `nice -n 10 taskpolicy -d throttle` (its default)
#   normal    GIT_FETCH_ONCE_PRIORITY=normal
# Each runs idle and under duress (SPIN `yes` spinners this script starts and stops), arms alternating run by run.
# Lines: `LANESTART {json}` per run, `LANESTART-SUMMARY {json}` per arm and load with n and p50/max in ms.
# Everything it makes is under one scratch root that it removes on exit.
set -euo pipefail

n_cold="${1:-3}"
n_warm="${2:-5}"
[ "$(uname -s)" = Darwin ] || { echo "lane-start-qos: macOS only" >&2; exit 2; }
command -v taskpolicy >/dev/null || { echo "lane-start-qos: no taskpolicy" >&2; exit 2; }
cores="$(sysctl -n hw.ncpu)"
spin="${3:-$((cores * 2))}"
for v in "$n_cold" "$n_warm" "$spin"; do [[ "$v" =~ ^[0-9]{1,3}$ ]] || { echo "lane-start-qos: counts are 0-999" >&2; exit 2; }; done
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rev="$(git -C "$repo" rev-parse HEAD)"

root="$(mktemp -d "${TMPDIR:-/tmp}/lanestart.XXXXXX")"
root="$(cd "$root" && pwd -P)"
spinners=()
stop_spin() {
  local p
  for p in "${spinners[@]+"${spinners[@]}"}"; do kill "$p" 2>/dev/null || true; done
  for p in "${spinners[@]+"${spinners[@]}"}"; do wait "$p" 2>/dev/null || true; done
  spinners=()
}
cleanup() {
  set +e
  stop_spin
  chmod -R u+w "$root" 2>/dev/null
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_spin() {
  local i
  for ((i = 0; i < spin; i++)); do yes >/dev/null & spinners+=("$!"); done
}

ms() { python3 -c 'import time; print(int(time.monotonic() * 1000))'; }

# The source a mirror clones and fetches, plus one new commit per warm run so a fetch has work.
src="$root/src"
# One commit of the step's tracked files (the step's checkout may be shallow, partial or projected, so it is not
# cloned itself): the files a worktree writes are the repo's, its history is not.
git init -q "$src"
# Only the files on disk: a sparse checkout lists paths it never wrote.
(cd "$repo" && git ls-files -z | python3 -c 'import os,sys
sys.stdout.buffer.write(b"".join(p + b"\0" for p in sys.stdin.buffer.read().split(b"\0") if p and os.path.lexists(p)))' |
  tar --null -T - -cf -) | tar -xf - -C "$src"
git -C "$src" add -A
git -C "$src" -c user.name=bench -c user.email=bench@localhost commit -q -m "lane-start-qos base $rev"
base="$(git -C "$src" rev-parse HEAD)"
seq_no=0
bump_src() {
  seq_no=$((seq_no + 1))
  local tree commit
  tree="$(git -C "$src" rev-parse "$base^{tree}")"
  commit="$(git -C "$src" -c user.name=bench -c user.email=bench@localhost commit-tree "$tree" -p "$base" \
    -m "lane-start-qos bump $seq_no")"
  git -C "$src" update-ref refs/heads/lane-start-bench "$commit"
}

# The start, as its own script so a prefix (taskpolicy, nice) runs all of it: START KIND MIRROR WT.
# reads: the six local git calls a second `wt new` made under the background prefix (lw#9927's count).
cat >"$root/start.sh" <<'START'
set -euo pipefail
kind="$1" src="$2" mirror="$3" wt="$4"
if [ "$kind" = cold ]; then
  git clone -q --bare --no-local "$src" "$mirror"
else
  git -C "$mirror" fetch --no-recurse-submodules -q "$src" "+refs/heads/*:refs/heads/*"
fi
git -C "$mirror" worktree add -q --detach "$wt" refs/heads/lane-start-bench
git -C "$mirror" rev-parse --verify -q "refs/heads/lane-start-bench^{commit}" >/dev/null
git -C "$mirror" for-each-ref --format='%(refname) %(objectname)' refs/heads >/dev/null
git -C "$mirror" config --get-regexp '^remote\.' >/dev/null || true
git -C "$wt" rev-parse --show-toplevel >/dev/null
git -C "$wt" ls-tree --name-only HEAD >/dev/null
git -C "$wt" --no-optional-locks status --porcelain >/dev/null
START

prefix_for() {  # arm -> the prefix the whole start runs under
  case "$1" in
    before) echo "taskpolicy -b" ;;
    after) echo "" ;;
    throttle) echo "nice -n 10 taskpolicy -d throttle" ;;
    normal) echo "" ;;
  esac
}

results="$root/results.jsonl"
: >"$results"
record() {  # kind arm load run ms
  local line
  line="$(printf '{"kind":"%s","arm":"%s","load":"%s","run":%d,"ms":%d,"cores":%d,"spin":%d}' "$1" "$2" "$3" "$4" "$5" "$cores" "$6")"
  echo "LANESTART $line"
  echo "$line" >>"$results"
}

run_id=0
start_arm() {  # kind arm load
  local kind="$1" arm="$2" load="$3" pre t0 t1
  run_id=$((run_id + 1))
  local mirror="$root/mirror-$run_id"
  if [ "$kind" = warm ]; then
    git clone -q --bare --no-local "$src" "$mirror"  # the mirror a warm start finds, made outside the timing
  fi
  bump_src
  pre="$(prefix_for "$arm")"
  t0="$(ms)"
  # shellcheck disable=SC2086
  $pre bash "$root/start.sh" "$kind" "$src" "$mirror" "$root/wt-$run_id"
  t1="$(ms)"
  record "$kind" "$arm" "$load" "$run_id" "$((t1 - t0))" "$([ "$load" = duress ] && echo "$spin" || echo 0)"
  git -C "$mirror" worktree remove --force "$root/wt-$run_id" 2>/dev/null || true
  chmod -R u+w "$mirror" "$root/wt-$run_id" 2>/dev/null || true
  rm -rf "$mirror" "$root/wt-$run_id"
}

fetch_arm() {  # arm load: git-fetch-once's network fetch, depth 1 of this commit from GitHub
  local arm="$1" load="$2" pre t0 t1 dir
  run_id=$((run_id + 1))
  dir="$root/fetch-$run_id"
  git init -q --bare "$dir"
  pre="$(prefix_for "$arm")"
  t0="$(ms)"
  # shellcheck disable=SC2086
  if ! $pre git -C "$dir" fetch --no-recurse-submodules -q --depth=1 https://github.com/manaflow-ai/cmux.git "$rev" 2>"$root/fetch.err"; then
    echo "lane-start-qos: fetch failed: $(head -c 300 "$root/fetch.err")" >&2
    rm -rf "$dir"
    return 0
  fi
  t1="$(ms)"
  record fetch "$arm" "$load" "$run_id" "$((t1 - t0))" "$([ "$load" = duress ] && echo "$spin" || echo 0)"
  rm -rf "$dir"
}

echo "lane-start-qos: rev $rev, $cores cores, spin $spin, n_cold $n_cold, n_warm $n_warm, host $(hostname -s)" >&2
for load in idle duress; do
  [ "$load" = duress ] && start_spin
  sleep 2
  for ((i = 0; i < n_warm; i++)); do
    if ((i % 2)); then a=(after before); else a=(before after); fi
    for arm in "${a[@]}"; do start_arm warm "$arm" "$load"; done
  done
  for ((i = 0; i < n_cold; i++)); do
    if ((i % 2)); then a=(after before); else a=(before after); fi
    for arm in "${a[@]}"; do start_arm cold "$arm" "$load"; done
  done
  for ((i = 0; i < n_cold; i++)); do  # a network fetch takes a minute or more: N_COLD of them
    if ((i % 2)); then a=(normal throttle); else a=(throttle normal); fi
    for arm in "${a[@]}"; do fetch_arm "$arm" "$load"; done
  done
  [ "$load" = duress ] && stop_spin
  uptime >&2
done

python3 - "$results" <<'PY'
import json, statistics, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
groups = {}
for r in rows:
    groups.setdefault((r["kind"], r["load"], r["arm"]), []).append(r["ms"])
for (kind, load, arm), v in sorted(groups.items()):
    print("LANESTART-SUMMARY " + json.dumps({"kind": kind, "load": load, "arm": arm, "n": len(v),
          "p50_ms": int(statistics.median(v)), "max_ms": max(v), "runs_ms": v}))
PY
