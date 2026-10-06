#!/usr/bin/env bash
# Behavior tests for scripts/blacksmith-testbox-approve.sh with fake `gh` and
# `blacksmith` binaries. No network. Each case writes a fixture of waiting
# warmup runs and what `blacksmith testbox status` prints, runs the helper,
# and checks which run (if any) it approved.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$root/scripts/blacksmith-testbox-approve.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin"

# fake gh: serves fixtures from $FIXTURE, records approvals in $FIXTURE/approved.
cat >"$bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
jq_filter=""; method=GET; path=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    api) ;;
    --jq) jq_filter="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    -X) method="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --input) i=$((i + 1)) ;;
    *) [[ -z "$path" ]] && path="${args[$i]}" ;;
  esac
done
out() { if [[ -n "$jq_filter" ]]; then jq -r "$jq_filter"; else cat; fi; }
case "$path" in
  user) printf '{"login":"lawrencecchen"}' | out ;;
  */actions/workflows/*/runs*) cat "$FIXTURE/runs.json" | out ;;
  */pending_deployments)
    run="$(printf '%s' "$path" | grep -Eo 'runs/[0-9]+' | cut -d/ -f2)"
    if [[ "$method" == POST ]]; then cat >/dev/null; echo "$run" >>"$FIXTURE/approved"; echo '[]'
    else printf '[{"environment":{"id":42}}]' | out; fi ;;
  */actions/runs/*)
    run="${path##*/}"
    jq -c --argjson id "$run" '.workflow_runs[] | select(.id == $id)' "$FIXTURE/runs.json" | out ;;
  *) echo "fake gh: unexpected $path" >&2; exit 9 ;;
esac
GH
cat >"$bin/blacksmith" <<'BS'
#!/usr/bin/env bash
cat "$FIXTURE/status.txt" 2>/dev/null || true
BS
chmod +x "$bin/gh" "$bin/blacksmith"

now="$(date +%s)"
iso() { python3 -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
run_json() { # id created_epoch status [title]
  local title="${4:-cmux-tui Rust Testbox setup}"
  printf '{"id":%s,"created_at":"%s","status":"%s","event":"workflow_dispatch","head_branch":"main","path":".github/workflows/cmux-tui-testbox-warmup.yml","display_title":"%s","actor":{"login":"blacksmith-sh[bot]"},"triggering_actor":{"login":"blacksmith-sh[bot]"}}' \
    "$1" "$(iso "$2")" "$3" "$title"
}
fixture() { # name runs... ; status line from $STATUS
  local dir="$work/$1"; shift
  mkdir -p "$dir"
  local joined; joined="$(IFS=,; echo "$*")"
  printf '{"workflow_runs":[%s]}' "$joined" >"$dir/runs.json"
  printf '%s\n' "${STATUS:-}" >"$dir/status.txt"
  echo "$dir"
}
run_helper() { # dir tbx dispatch -> sets rc and out
  set +e
  out="$(FIXTURE="$1" PATH="$bin:$PATH" CMUX_TESTBOX_APPROVE_WAIT=3 CMUX_TESTBOX_APPROVE_POLL=1 "$helper" "$2" "$3" test 2>&1)"
  rc=$?
  set -e
}
approved_of() { cat "$1/approved" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
fail() { echo "FAIL: $*" >&2; echo "$out" >&2; exit 1; }

tbx=tbx_01testboxaaaaaaaaaaaaaaaaaa
header="ID STATUS REPO WORKFLOW JOB REF CREATED RUN URL"

# 1. The box is still queued (no RUN URL yet) and its waiting run's title
#    names the box: approve it. (The old helper waited for a run URL that
#    only appears after approval: a deadlock.)
STATUS="$header
$tbx queued cmux warmup.yml cmux-tui-rust main x" \
  d="$(fixture one "$(run_json 501 $((now + 5)) waiting "cmux-tui Rust Testbox setup $tbx")" "$(run_json 400 $((now - 4000)) waiting)")"
run_helper "$d" "$tbx" "$now"
[[ $rc -eq 0 && "$(approved_of "$d")" == 501 ]] || fail "case 1: expected run 501 approved (rc=$rc, approved=$(approved_of "$d"))"
[[ "$(printf '%s\n' "$out" | tail -1)" == 501 ]] || fail "case 1: the last output line must be the run id"

# 2. A single untitled run right after the dispatch is NOT proof: another
#    operator's run can appear first inside any time window. Refuse.
STATUS="$header
$tbx queued cmux warmup.yml cmux-tui-rust main x" \
  d="$(fixture window "$(run_json 601 $((now + 3)) waiting)")"
run_helper "$d" "$tbx" "$now"
[[ $rc -eq 3 && -z "$(approved_of "$d")" ]] || fail "case 2: expected refusal (rc=$rc)"

# 3. Two runs both titled with this box: refuse.
STATUS="" d="$(fixture dup "$(run_json 701 $((now + 1)) waiting "cmux-tui Rust Testbox setup $tbx")" "$(run_json 702 $((now + 2)) waiting "cmux-tui Rust Testbox setup $tbx")")"
run_helper "$d" "$tbx" "$now"
[[ $rc -eq 3 && -z "$(approved_of "$d")" ]] || fail "case 3: expected refusal (rc=$rc)"

# 4. A run whose title names this box wins over the window, even with others.
STATUS="" d="$(fixture titled "$(run_json 801 $((now + 2)) waiting)" "$(run_json 802 $((now + 4)) waiting "cmux-tui Rust Testbox setup $tbx")")"
run_helper "$d" "$tbx" "$now"
[[ $rc -eq 0 && "$(approved_of "$d")" == 802 ]] || fail "case 4: expected run 802 (rc=$rc, approved=$(approved_of "$d"))"

# 5. A run whose title names ANOTHER box is never approved, even if alone.
STATUS="" d="$(fixture other "$(run_json 901 $((now + 2)) waiting "cmux-tui Rust Testbox setup tbx_01someoneelsebbbbbbbbbbbbbb")")"
run_helper "$d" "$tbx" "$now"
[[ $rc -eq 3 && -z "$(approved_of "$d")" ]] || fail "case 5: expected refusal (rc=$rc)"

# 6. The status shows the run URL: approve that run when it is waiting.
STATUS="$header
$tbx queued cmux warmup.yml cmux-tui-rust main x https://github.com/manaflow-ai/cmux/actions/runs/1001" \
  d="$(fixture url "$(run_json 1001 $((now + 2)) waiting)" "$(run_json 1002 $((now + 3)) waiting)")"
run_helper "$d" "$tbx" "$now"
[[ $rc -eq 0 && "$(approved_of "$d")" == 1001 ]] || fail "case 6: expected run 1001 (rc=$rc, approved=$(approved_of "$d"))"

# 7. The run URL points at a run that is not waiting: refuse.
STATUS="$header
$tbx ready cmux warmup.yml cmux-tui-rust main x https://github.com/manaflow-ai/cmux/actions/runs/1101" \
  d="$(fixture done "$(run_json 1101 $((now + 2)) completed)")"
run_helper "$d" "$tbx" "$now"
[[ $rc -eq 3 && -z "$(approved_of "$d")" ]] || fail "case 7: expected refusal (rc=$rc)"

echo "ok: 7 approval cases"
