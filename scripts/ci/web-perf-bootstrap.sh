#!/usr/bin/env bash
# One Linux fast-checks command; keep its snapshot HEAD unchanged for the runner receipt.
set -euo pipefail

head_sha="${1:?full pushed integration head required}"
base_sha="${2:?full target base SHA required}"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ && "$base_sha" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$(uname -s)" == Linux ]] || { echo "web perf measurements require managed Linux" >&2; exit 2; }
snapshot="$(git rev-parse --show-toplevel)"
snapshot_head="$(git rev-parse HEAD)"
task_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/web-perf-bootstrap.XXXXXXXX")"
measured="$task_root/source"
evidence="$task_root/evidence"
mkdir -p "$evidence/traces"
cleanup() {
  git -C "$snapshot" worktree remove --force "$measured" >/dev/null 2>&1 || true
  rm -rf "$task_root"
}
trap cleanup EXIT
# Bound the download only where the checkout is already shallow; never turn a full clone shallow.
depth=()
[[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
git fetch --no-tags "${depth[@]}" origin "$head_sha" "$base_sha"
git worktree add --detach "$measured" "$head_sha"
cd "$measured/webviews"
test "$(git rev-parse HEAD)" = "$head_sha"
bun install --frozen-lockfile
"$snapshot/scripts/ci/ensure-system-chrome.sh"
set +e
bun scripts/latency/run.ts --ci --no-fail --engine chromium --pages "chat flows,chat 3000 paged,chat 3000 resident,chat rail" --runs 10 --base "$base_sha" \
  --trace-dir "$evidence/traces" --json "$evidence/results.json" --require longTasks,reactCommits,cpu
harness_status=$?
bootstrap_status=1
if [[ -s "$evidence/results.json" ]]; then
  bun scripts/latency/bootstrap.ts --results "$evidence/results.json" --budget test/latency/budget.json \
    --expected-head "$head_sha" --expected-base "$base_sha" --traces "$evidence/traces" \
    --artifact-url "https://github.com/manaflow-ai/cmux/actions/runs/${GITHUB_RUN_ID:?Actions run required}" \
    --output "$evidence/baseline.json" --report "$evidence/report.md"
  bootstrap_status=$?
fi
set -e
printf 'head=%s\nbase=%s\nharness_status=%s\nbootstrap_status=%s\n' \
  "$head_sha" "$base_sha" "$harness_status" "$bootstrap_status" > "$evidence/status.txt"
tar -C "$evidence" -czf "$task_root/evidence.tar.gz" .
if [[ -n "${FAST_CHECKS_OUT:-}" ]]; then
  # fast-checks uploads FAST_CHECKS_OUT as its fast-checks-output artifact, which a long log can't truncate.
  cp "$task_root/evidence.tar.gz" "$FAST_CHECKS_OUT/web-perf-evidence.tar.gz"
  (cd "$FAST_CHECKS_OUT" && sha256sum web-perf-evidence.tar.gz | tee web-perf-evidence.tar.gz.sha256)
else
  # Outside fast-checks: keep the complete compressed evidence in the retained log.
  sha256sum "$task_root/evidence.tar.gz"
  printf '%s\n' WEB_PERF_EVIDENCE_BASE64_START
  base64 -w 76 "$task_root/evidence.tar.gz"
  printf '%s\n' WEB_PERF_EVIDENCE_BASE64_END
fi
test "$(git -C "$snapshot" rev-parse HEAD)" = "$snapshot_head"
test "$harness_status" = 0 && test "$bootstrap_status" = 0
