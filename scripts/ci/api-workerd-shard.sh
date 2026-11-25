#!/usr/bin/env bash
# Run one shard of the API Worker suite on workerd (backend.yml), from backend/apps/api.
#
#   bash scripts/ci/api-workerd-shard.sh <shard> [<total>]
#
# The api-workerd matrix job runs it for its shard, and the `test` job runs it again for a shard whose job died
# without a test verdict (a lost runner, a stalled setup step, the job limit on a slow host; cmux#56511 and
# scripts/ci/api_workerd_infra_shards.py), so both answer the same way.
#
# A packed cmux-linux runner shares its VM's vCPUs with up to 3 others (#48644) but nproc still reports all 16, so
# vitest's default (one worker per vCPU) started 15 workerd isolates per job, 60 on 16 CPUs: imports took 40 to
# 100 s and 0.5 s cases ran past their 20 s bound (runs 45159322542, 45166603179, 45168037835, 45172851459).
# Measured on shard 2/6 pinned to 4 CPUs, 2026-11-23: 15 workers: 416 s, 2 files failed; 4 workers: 451 s,
# 228/228 passed. Even at 4, 6 shards still hit start and hook timeouts (45172479573), so: 12 shards of at most 3
# workers. A load timeout on a busy VM is not the code's: the files that failed run once more and that run
# decides; a real failure fails both, and the first run's log stays above.
# The retry runs only the failed files, one at a time when 6 or fewer. Rerunning the whole shard on the same slow
# host (cmux-runner-pool-h*, where bun install takes 33 to 40 s against 1 to 4 s and a shard 1150 to 2160 s against
# about 190 s) timed out a different set of files the second time: shard 4/12 of run 45595544453 failed 3 files,
# then 2 others; 5/12 and 7/12 of run 45588309799 the same (cmux#56145). A file alone is far from its bounds.
# With no failed file in the report (an unhandled error, a crash before the report), the whole shard reruns.
set -uo pipefail

shard="${1:?usage: api-workerd-shard.sh <shard> [<total>]}"
total="${2:-12}"
[[ "$shard" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] || { echo "api-workerd-shard.sh: shard and total are numbers" >&2; exit 2; }

n=$(nproc); [ "$n" -gt 3 ] && n=3
report="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/api-workerd-$shard-$$.json"
VITEST_JSON_OUT="$report" bun run test --shard="$shard/$total" --maxWorkers="$n" && exit 0
failed=(); while IFS= read -r f; do failed+=("$f"); done < <(node -e 'for (const f of require(process.argv[1]).testResults) if (f.status === "failed") console.log(f.name)' "$report" 2>/dev/null || true)
if [ "${#failed[@]}" -eq 0 ]; then
  echo "::warning::api-workerd shard $shard/$total failed once with no failed file in its report; running the whole shard again"
  bun run test --shard="$shard/$total" --maxWorkers="$n"
  exit
fi
w=1; [ "${#failed[@]}" -gt 6 ] && w="$n"
echo "::warning::api-workerd shard $shard/$total failed once in ${#failed[@]} files; running those again with $w worker(s) (a load timeout on a packed runner, or a real failure that fails again)"
printf '  %s\n' "${failed[@]}"
bun run test --maxWorkers="$w" "${failed[@]}"
