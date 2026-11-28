#!/usr/bin/env bash
# p50/p95 of a subagent pane's newest-page open (acpmux `subagent_newest_page_perf`), before and after, from
# one harness: this checkout's bench is copied into a scratch worktree of BEFORE_SHA (default: the merge-base
# with origin/feat-cmux-next), both built with `--profile gate`, and run quiet and then with every core busy.
#   cmux-ci test -- bash scripts/measure/subagent-newest-page-p95.sh [BEFORE_SHA]
# Prints "P95-RUN side=before|after load=quiet|duress" before each run's bench lines.
set -uo pipefail
root="$(git rev-parse --show-toplevel)"
test_file=cmux-tui/crates/acpmux/src/hub/paging_tests.rs
start="/// The subagent pane's open as \`readSubagentLog\` makes it"
before="${1:-$(git -C "$root" merge-base HEAD origin/feat-cmux-next 2>/dev/null)}"
[ -n "$before" ] || { git -C "$root" fetch --no-recurse-submodules -q origin feat-cmux-next && before="$(git -C "$root" merge-base HEAD FETCH_HEAD)"; }
scratch="$(mktemp -d)"
burners=()
cleanup() {
  for pid in ${burners[@]+"${burners[@]}"}; do kill "$pid" 2>/dev/null; done
  git -C "$root" worktree remove --force "$scratch/before" >/dev/null 2>&1
  rm -rf "$scratch"
}
trap cleanup EXIT
git -C "$root" worktree add -q --detach "$scratch/before" "$before" || exit 1
# The bench is the text from its doc comment to the next test's; the before tree gets it appended (its own
# older copy, if any, is renamed so the filter picks only this one).
python3 - "$root/$test_file" "$scratch/before/$test_file" "$start" <<'PY'
import sys
head, before, start = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(head).read()
a = s.index(start)
b = s.index("/// A subagent's newest page skips", a)
old = open(before).read().replace("fn subagent_newest_page_perf(", "fn subagent_newest_page_perf_old(")
open(before, "w").write(old + "\n" + s[a:b])
PY
status=0
for side in before after; do
  dir="$root"; [ "$side" = before ] && dir="$scratch/before"
  (cd "$dir/cmux-tui" && cargo test --profile gate -p acpmux --lib --no-run -q) || { echo "P95-BUILD-FAIL side=$side"; status=1; }
done
for load in quiet duress; do
  if [ "$load" = duress ]; then
    for _ in $(seq "$(nproc)"); do (while :; do :; done) & burners+=("$!"); done
  fi
  for side in before after; do
    dir="$root"; [ "$side" = before ] && dir="$scratch/before"
    echo "P95-RUN side=$side load=$load sha=$(git -C "$dir" rev-parse --short=12 HEAD) nproc=$(nproc) load_avg=\"$(cut -d' ' -f1-3 /proc/loadavg)\""
    (cd "$dir/cmux-tui" && cargo test --profile gate -p acpmux --lib -q -- --ignored --nocapture --exact \
      hub::paging::paging_tests::subagent_newest_page_perf 2>&1 | grep -E "subagent newest page|panicked|test result") || true
  done
  for pid in ${burners[@]+"${burners[@]}"}; do kill "$pid" 2>/dev/null; done
  burners=()
done
exit "$status"
