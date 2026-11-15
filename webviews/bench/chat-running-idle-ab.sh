#!/usr/bin/env bash
# A/B of a running chat's idle CPU and wakeups (chat-100k-flat.bench.ts, CASES=running WAKES=1): the pane's FILES at
# two commits, one launch of each in turn (A B A B ...) on the same runner, so host load falls on both alike. Each
# launch reads REPEAT (3) idle windows; the summary gives each side's running_x1 idle CPU and wakeups, median and range
# over every window. Only FILES change between the sides: the bench, its stand-in daemon and everything else stay
# the checkout's.
#   bench/chat-running-idle-ab.sh A_SHA B_SHA [rounds=6] [rows=100000]
# FILES (paths under webviews/, space separated) defaults to src/agent-session/acpmux/direct.ts. Logs go to
# $FAST_CHECKS_OUT when set (a cmux-ci test run), else a new temp dir.
set -euo pipefail
cd "$(dirname "$0")/.."
a_sha=${1:?usage: bench/chat-running-idle-ab.sh A_SHA B_SHA [rounds] [rows]}
b_sha=${2:?usage: bench/chat-running-idle-ab.sh A_SHA B_SHA [rounds] [rows]}
rounds=${3:-6}
rows=${4:-100000}
files=${FILES:-src/agent-session/acpmux/direct.ts}
out=${FAST_CHECKS_OUT:-$(mktemp -d)}
mkdir -p "$out/ab-src"

# Each side's copy of each file: from git when the commit is here or fetchable, else GitHub's raw file (a CI
# checkout is shallow and keeps no credential; the repository is public).
# A depth flag only in a checkout that is already shallow (a CI one): in a full clone it would turn every worktree of
# it shallow (tests/test_ci_no_shallow_dev_fetch.py).
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
for side in a b; do
  sha=$a_sha
  [[ $side == b ]] && sha=$b_sha
  if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
    git fetch -q ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$sha" 2>/dev/null || true
  fi
  for file in $files; do
    dest="$out/ab-src/$side/$file"
    mkdir -p "$(dirname "$dest")"
    if ! git show "$sha:webviews/$file" >"$dest" 2>/dev/null; then
      curl -fsSL --retry 3 --retry-all-errors "https://raw.githubusercontent.com/manaflow-ai/cmux/$sha/webviews/$file" -o "$dest"
    fi
  done
done

mkdir -p "$out/ab-src/checkout"
for file in $files; do
  mkdir -p "$(dirname "$out/ab-src/checkout/$file")"
  cp "$file" "$out/ab-src/checkout/$file"
done
restore() {
  for file in $files; do cp "$out/ab-src/checkout/$file" "$file"; done
}
trap restore EXIT

for round in $(seq 1 "$rounds"); do
  for side in a b; do
    for file in $files; do cp "$out/ab-src/$side/$file" "$file"; done
    log="$out/ab-$side-$round.log"
    echo "chat-running-idle-ab: round $round side $side"
    CASES=running WAKES=1 RESIZE=0 bun bench/chat-100k-flat.bench.ts "$rows" 2 >"$log" 2>&1 || {
      echo "chat-running-idle-ab: round $round side $side failed"
      tail -40 "$log"
      exit 1
    }
    grep -E "running_x1: (idle window|CPU settled|grew)|^running_x1 \|" "$log" || true
  done
done

# idle window lines: "  running_x1: idle window N C % cpu; wakes/s: switches S, timers T, raf R, posts P, mutations M"
summary() {
  local side=$1 sha=$2
  cat "$out"/ab-"$side"-*.log | grep -E "running_x1: idle window [0-9]+ " |
    sed -E 's/.*idle window [0-9]+ ([0-9.]+) % cpu; wakes\/s: switches ([0-9.]+), timers ([0-9.]+), raf ([0-9.]+), posts ([0-9.]+), mutations ([0-9.]+)/\1 \2 \3 \4 \5 \6/' |
    awk -v side="$side" -v sha="${sha:0:10}" '
      { n++; for (i = 1; i <= 6; i++) v[i, n] = $i }
      END {
        split("idle_cpu_pct switches/s timers/s raf/s posts/s mutations/s", names, " ")
        printf "%s %s windows=%d", side, sha, n
        for (i = 1; i <= 6; i++) {
          m = 0
          for (j = 1; j <= n; j++) col[j] = v[i, j]
          # insertion sort
          for (j = 2; j <= n; j++) { x = col[j]; k = j - 1; while (k >= 1 && col[k] > x) { col[k + 1] = col[k]; k-- } col[k + 1] = x }
          med = n % 2 ? col[(n + 1) / 2] : (col[n / 2] + col[n / 2 + 1]) / 2
          printf " | %s median %.2f range %.2f-%.2f", names[i], med, col[1], col[n]
        }
        printf "\n"
      }'
}
echo "chat-running-idle-ab: running_x1 idle, every window (rows $rows, $rounds rounds of A B)"
summary a "$a_sha" | tee "$out/ab-summary.txt"
summary b "$b_sha" | tee -a "$out/ab-summary.txt"
for side in a b; do
  echo "chat-running-idle-ab: side $side windows (cpu %):" $(cat "$out"/ab-"$side"-*.log | grep -E "running_x1: idle window [0-9]+ " | sed -E 's/.*idle window [0-9]+ ([0-9.]+) % cpu.*/\1/')
  echo "chat-running-idle-ab: side $side empty_x1 idle medians:" $(grep -h "^empty_x1 |" "$out"/ab-"$side"-*.log | awk -F'|' '{print $3}')
done
