#!/usr/bin/env bash
# TEMPORARY (perf 24569 group 2): the fix's red/green tests and its before/after benches, in one CI job.
# Delete before merge.
#   bench/verify-chat-switch-g2.sh BEFORE_SHA AFTER_SHA [flat]
# BEFORE_SHA is the commit with the regression test but not the fix; AFTER_SHA has the fix.
set -uo pipefail
before="$1" after="$2" flat="${3:-}"
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
git fetch -q --no-tags --depth=2 origin "$before" "$after" 2>&1 | tail -2 || true
fixed=(src/agent-session/acpmux/direct.ts src/agent-session/acpmux/conversation/olderAhead.ts
  src/agent-session/acpmux/VirtualTranscript.tsx src/agent-session/acpmux/App.tsx)
tests=(src/agent-session/acpmux/olderPageAtRest.test.ts src/agent-session/acpmux/conversation/olderAhead.test.ts
  src/agent-session/acpmux/olderPagingBench.test.ts)

echo "== green: the tests at the fix"
bun test "${tests[@]}" 2>&1 | tail -15; echo "GREEN_RC=${PIPESTATUS[0]}"
echo "== red: the same tests over the sources before the fix ($before)"
for f in "${fixed[@]}"; do git show "$before:webviews/$f" > "$f"; done
bun test "${tests[@]}" 2>&1 | grep -E "^\(fail\)|^\(pass\)|Expected|Received|^ *[0-9]+ (pass|fail)" | head -30; echo "RED_RC=${PIPESTATUS[0]}"
git checkout -q -- "${fixed[@]}"
echo "== the history paging and reopened-chat tests at the fix"
bun test src/agent-session/acpmux test/reopened-chat-history.test.ts test/agent-pane-history-paging.test.ts \
  test/agent-pane-restore-long-turn.test.ts 2>&1 | grep -E "^\(fail\)|^ *[0-9]+ (pass|fail)|^Ran " | tail -20
echo "SUITE_RC=${PIPESTATUS[0]}"
echo "== typecheck"
bun run typecheck 2>&1 | tail -8; echo "TYPECHECK_RC=${PIPESTATUS[0]}"

echo "== chat-switch before/after (one at a time)"
OUT_SUB=switch PAR=1 bash bench/bisect-chat-switch.sh "$before:both" "$after:both" "$before:both:r.2" "$after:both:r.2" \
  | grep -E '^(BISECT|REST|DONE|FAIL)'
if [[ "$flat" == flat ]]; then
  echo "== chat-100k-flat before/after (CASES=main, one at a time)"
  OUT_SUB=flat PAR=1 CASES=main BENCH=chat-100k-flat.bench.ts BENCH_ARGS="100000 20" BENCH_TIMEOUT=1500 \
    bash bench/bisect-chat-switch.sh "$before:plain" "$after:plain" | grep -E '^(BISECT|DONE|FAIL)'
fi
