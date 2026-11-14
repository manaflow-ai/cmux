#!/bin/bash
# Behavior test for nightly.sh with a fake `sr` and `cmux` on PATH and a throwaway git remote.
# Checks: dry run starts no worker and keeps no state; a real run audits only the new range,
# saves the state, and raises a notification for high findings; a second run with no new
# commits starts no worker. Usage: bash test_nightly.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$T/bin"
cat > "$T/bin/sr" <<'SR'
#!/bin/bash
out=""; prev=""; for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
echo "$PWD ${@: -1}" >> "$FAKE_LOG"
echo "route=${SUBROUTER_CODEX_BASE_URL:-unset} account=${SUBROUTER_CODEX_ACCOUNT_ID:-unset}" >> "$FAKE_LOG"
printf '# report\nCOUNTS critical=0 high=1 medium=0 low=0\n' > "$out"
SR
cat > "$T/bin/cmux" <<'CM'
#!/bin/bash
echo "cmux $*" >> "$FAKE_LOG"
CM
chmod +x "$T/bin/sr" "$T/bin/cmux"
git init -q --bare "$T/remote.git"
git clone -q "$T/remote.git" "$T/work" 2>/dev/null
cd "$T/work"; git checkout -q -b main
old="$(( $(date +%s) - 3 * 86400 )) +0000"
mkdir -p a b; echo 1 > a/x; echo 1 > b/y; git add .
GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git -c user.email=t@t -c user.name=t commit -qm base
git push -q origin main
git clone -q "$T/remote.git" "$T/checkout"
echo 2 > a/x; git -c user.email=t@t -c user.name=t commit -qam "touch a"; git push -q origin main
export PATH="$T/bin:$PATH" FAKE_LOG="$T/fake.log"
export CMUX_DAYBREAK_STATE_DIR="$T/state" CMUX_DAYBREAK_OUT_DIR="$T/out" CMUX_DAYBREAK_WORKTREE_DIR="$T/wt"
export CMUX_DAYBREAK_PROMPT="$HERE/prompt.md"
export CMUX_DAYBREAK_REPOS="demo|$T/checkout|main|lanea=a;laneb=b"
touch "$FAKE_LOG"

bash "$HERE/nightly.sh" --dry-run 2>/dev/null
[[ ! -s "$FAKE_LOG" ]] || fail "dry run started a worker"
[[ ! -e "$T/state/last-demo.sha" ]] || fail "dry run saved state"

bash "$HERE/nightly.sh" 2>/dev/null || fail "run failed"
[[ "$(grep -c 'demo' "$FAKE_LOG" | tr -d ' ')" -ge 1 ]] || fail "no worker started"
grep -q 'lane lanea' "$FAKE_LOG" || fail "lane a (changed) not audited"
! grep -q 'lane laneb' "$FAKE_LOG" || fail "lane b (unchanged) was audited"
[[ "$(cat "$T/state/last-demo.sha")" == "$(git -C "$T/work" rev-parse HEAD)" ]] || fail "state not saved"
grep -q 'cmux notification create --level error' "$FAKE_LOG" || fail "no notification for a high finding"
# The worker goes to the cmux-lawrence subrouter, the route that holds the Daybreak account;
# the machine's default sr server (sr2) does not have it.
grep -q 'route=http://100.89.225.106:31415/v1 account=lawrence@manaflow.ai' "$FAKE_LOG" || fail "worker not pinned to the cmux-lawrence route"
[[ "$(stat -f %Lp "$T/state")" == "700" ]] || fail "state dir is not 0700"

: > "$FAKE_LOG"
bash "$HERE/nightly.sh" 2>/dev/null || fail "second run failed"
! grep -q 'demo' "$FAKE_LOG" || fail "second run audited an empty range"
# A worker that fails fast logs the model error, not a lane timeout, and the state stays put.
echo 4 > "$T/work/a/x"; git -C "$T/work" -c user.email=t@t -c user.name=t commit -qam "touch a for failure"; git -C "$T/work" push -q origin main
cat > "$T/bin/sr" <<'SR'
#!/bin/bash
echo '{"type":"turn.failed","error":{"message":"unexpected status 503 Service Unavailable: requested account not found"}}'
exit 1
SR
before="$(cat "$T/state/last-demo.sha")"
if bash "$HERE/nightly.sh" 2>/dev/null; then fail "failed worker run reported success"; fi
[[ "$(cat "$T/state/last-demo.sha")" == "$before" ]] || fail "state advanced past a failed lane"
run_log="$(ls "$T"/out/*/run.log | tail -1)"
grep -q 'requested account not found' "$run_log" || fail "run log does not name the worker's model error"
! grep -q 'lane timeout' "$run_log" || fail "a fast failure was logged as a lane timeout"
: > "$run_log"
# A hung worker is stopped at the lane timeout, the run fails, and the state stays put.
echo 3 > "$T/work/a/x"; git -C "$T/work" -c user.email=t@t -c user.name=t commit -qam "touch a again"; git -C "$T/work" push -q origin main
cat > "$T/bin/sr" <<'SR'
#!/bin/bash
# Like the real sr: a child process does the work.
sleep 600 &
echo $! > "$FAKE_CHILD"
wait
SR
export FAKE_CHILD="$T/child.pid"
before="$(cat "$T/state/last-demo.sha")"
start=$(date +%s)
if CMUX_DAYBREAK_LANE_TIMEOUT=2 bash "$HERE/nightly.sh" 2>/dev/null; then fail "hung worker run reported success"; fi
[[ $(( $(date +%s) - start )) -lt 60 ]] || fail "lane timeout did not stop the hung worker"
[[ "$(cat "$T/state/last-demo.sha")" == "$before" ]] || fail "state advanced past an unaudited range"
grep -q 'lane timeout' "$run_log" || fail "a hung worker was not logged as a lane timeout"
sleep 1
! kill -0 "$(cat "$FAKE_CHILD")" 2>/dev/null || { kill "$(cat "$FAKE_CHILD")"; fail "the hung worker's child process was left running"; }
echo "PASS"
