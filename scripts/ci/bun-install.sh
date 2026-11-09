#!/usr/bin/env bash
# `bun install` for CI, bounded: a registry connection that hangs ends with a clear reason and a retry,
# never a job that sits silent until its timeout cancels it.
#
# Why (2026-11-09): from about 14:50Z the package registry stopped answering some connections from the hosted
# Linux runners. Bun waits on a hung connection with no idle timeout of its own, so `bun install --frozen-lockfile`
# printed "Resolved, downloaded and extracted [3]" and then nothing until web-complexity.yml's 10-minute limit
# cancelled the job, which merge_hold then refused. The same registry answered in under a second from another network.
#
# Usage, in the package's folder: bash scripts/ci/bun-install.sh [bun install args...]
#   (default args: --frozen-lockfile; a lone `--` first means exactly the args after it, none included,
#   for a step that runs a plain `bun install`)
# Every workflow's bun install goes through here (tests/test_ci_required_checks_are_bounded.py fails on a bare one).
# Knobs (environment, each with a default):
#   BUN_CONFIG_HTTP_IDLE_TIMEOUT  seconds a registry connection may sit idle before bun drops and retries it (30)
#   BUN_CONFIG_HTTP_RETRY_COUNT   bun's own retries of one failed request (5)
#   BUN_INSTALL_ATTEMPT_SECONDS   one attempt's deadline (300)
#   BUN_INSTALL_ATTEMPTS          attempts before the step fails (2)
# A second attempt keeps what the first downloaded (bun's package cache), so a slow registry makes the step
# slower and a hung one makes it retry; only a registry that stays unreachable fails it, with that reason.
set -uo pipefail

export BUN_CONFIG_HTTP_IDLE_TIMEOUT="${BUN_CONFIG_HTTP_IDLE_TIMEOUT:-30}"
export BUN_CONFIG_HTTP_RETRY_COUNT="${BUN_CONFIG_HTTP_RETRY_COUNT:-5}"
attempt_seconds="${BUN_INSTALL_ATTEMPT_SECONDS:-300}"
attempts="${BUN_INSTALL_ATTEMPTS:-2}"
registry="${BUN_CONFIG_REGISTRY:-${NPM_CONFIG_REGISTRY:-https://registry.npmjs.org/}}"
# The registry as the log shows it: any user:password@ in the URL removed.
shown_registry="$(printf '%s' "$registry" | sed -E 's#^([a-z]+://)[^/@]*@#\1#')"
runner="${RUNNER_NAME:-$(hostname)}"

for value in "$BUN_CONFIG_HTTP_IDLE_TIMEOUT" "$BUN_CONFIG_HTTP_RETRY_COUNT" "$attempt_seconds" "$attempts"; do
  # Zero is refused too: `timeout 0` never fires, which would undo the bound.
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "bun-install: '$value' is not a positive whole number" >&2
    exit 2
  fi
done
if [ "$#" -eq 0 ]; then
  set -- --frozen-lockfile
elif [ "$1" = "--" ]; then
  shift
fi

# One attempt under its deadline. A host with no coreutils `timeout` (a stock macOS runner) gets the same bound
# from a watchdog on this attempt's own PID; either way 124 means the deadline ended it.
bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=15 "$attempt_seconds" "$@"
    return
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=15 "$attempt_seconds" "$@"
    return
  fi
  local marker pid watchdog code
  marker="$(mktemp)"
  rm -f "$marker"
  # Job control puts the attempt in its own process group, so the deadline ends bun and every lifecycle script it
  # started (a postinstall can outlive bun and hold the step's log open), not bun alone.
  set -m
  "$@" &
  pid=$!
  set +m
  # The watchdog's own sleep goes with it (the trap), so nothing it started outlives the attempt or holds the log open.
  (
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM
    sleep "$attempt_seconds" & nap=$!
    wait "$nap"
    : > "$marker"
    kill -TERM -- "-$pid" 2>/dev/null
    sleep 15 & nap=$!
    wait "$nap"
    kill -KILL -- "-$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid"
  code=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  if [ -e "$marker" ]; then
    rm -f "$marker"
    # Whatever of the group ignored TERM and is still there.
    kill -KILL -- "-$pid" 2>/dev/null
    return 124
  fi
  return "$code"
}

# One timed request to the registry, so the log says how it answered from this runner before the install.
probe() {
  curl --silent --output /dev/null --connect-timeout 5 --max-time 10 \
    --write-out 'HTTP %{http_code} in %{time_total}s from %{remote_ip}' "${registry%/}/react" 2>/dev/null || true
}
echo "bun-install: registry ${shown_registry} answers $(probe) (runner ${runner})"

attempt=1
while :; do
  started=$SECONDS
  bounded bun install "$@"
  code=$?
  took=$((SECONDS - started))
  if [ "$code" -eq 0 ]; then
    echo "bun-install: installed in ${took}s (attempt ${attempt}/${attempts})"
    exit 0
  fi
  # 124: timeout's own deadline; 137 only after its --kill-after, so an attempt that ended early with 137 was killed
  # by something else (the kernel's OOM killer), not timed out.
  if [ "$code" -eq 124 ] || { [ "$code" -eq 137 ] && [ "$took" -ge "$attempt_seconds" ]; }; then
    reason="no result in ${attempt_seconds}s"
    title="bun install stalled"
  else
    reason="exit ${code} after ${took}s"
    title="bun install failed"
  fi
  if [ "$attempt" -ge "$attempts" ]; then
    echo "::error title=${title}::bun install: ${reason} on attempt ${attempt}/${attempts} in $(pwd). The registry ${shown_registry} now answers $(probe) from ${runner}. A stall or a registry timeout is not a code failure: rerun the job. A lockfile or resolution error in the log above is."
    exit 1
  fi
  echo "::warning title=bun install retry::bun install: ${reason} on attempt ${attempt}/${attempts}; the registry now answers $(probe). Retrying; what it downloaded stays in bun's cache."
  attempt=$((attempt + 1))
done
