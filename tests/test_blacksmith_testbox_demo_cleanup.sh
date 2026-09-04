#!/usr/bin/env bash
# Exercise the demo's run binding and EXIT cleanup without dispatching CI.
# The fake CLI models the races that used to leave the warmup workflow running:
# manual approval, multiple newly visible waiting runs, and a failed warmup
# transcript that contains a stale Testbox ID, and a partial dispatch that can
# be recovered only through an exact ID-specific status check.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$ROOT_DIR/scripts/blacksmith-testbox-demo.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_case() {
  local mode="$1"
  local option="$2"
  local expected_run="$3"
  local expected_status="${4:-0}"
  local case_root="$TMP_DIR/$mode"
  local bin_dir="$case_root/bin"
  local output="$case_root/output.log"
  local cancel_log="$case_root/cancel.log"
  local approval_log="$case_root/approval.log"
  local stop_log="$case_root/stop.log"
  local blacksmith_log="$case_root/blacksmith.log"
  local bounded_log="$case_root/bounded.log"
  local mktemp_log="$case_root/mktemp.log"
  local waiting_calls="$case_root/waiting-calls"
  local status_calls="$case_root/status-calls"
  local warmup_started="$case_root/warmup-started"
  local warmup_release="$case_root/warmup-release"
  local testbox_id="tbx_demo_fixture_01"

  mkdir -p "$bin_dir" "$case_root/scripts" "$case_root/ghostty"
  cp "$DEMO" "$case_root/scripts/blacksmith-testbox-demo.sh"
  chmod +x "$case_root/scripts/blacksmith-testbox-demo.sh"
  : > "$case_root/.github-workflow-placeholder"
  mkdir -p "$case_root/.github/workflows"
  : > "$case_root/.github/workflows/cmux-tui-testbox-warmup.yml"
  : > "$case_root/ghostty/build.zig.zon"
  : > "$cancel_log"
  : > "$approval_log"
  : > "$stop_log"
  : > "$bounded_log"
  : > "$mktemp_log"
  rm -f "$warmup_started" "$warmup_release"
  printf '0\n' > "$waiting_calls"
  printf '0\n' > "$status_calls"

  cat > "$case_root/scripts/blacksmith-bounded-command.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_BOUNDED_LOG"
shift
exec "$@"
STUB
  chmod +x "$case_root/scripts/blacksmith-bounded-command.sh"

  cat > "$bin_dir/tee" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$CMUX_TEST_MODE" == "tee-fails" ]]; then
  /usr/bin/tee "$@"
  exit 19
fi
exec /usr/bin/tee "$@"
STUB
  chmod +x "$bin_dir/tee"

  cat > "$bin_dir/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "rev-parse --show-toplevel")
    printf '%s\n' "$CMUX_CASE_ROOT"
    ;;
  "symbolic-ref --short")
    printf '%s\n' 'fixture-branch'
    ;;
  "rev-parse HEAD:ghostty")
    printf '%s\n' '2222222222222222222222222222222222222222'
    ;;
  "rev-parse HEAD")
    printf '%s\n' '1111111111111111111111111111111111111111'
    ;;
  status\ *)
    ;;
  ls-remote\ *)
    printf '%s\trefs/heads/fixture-branch\n' '1111111111111111111111111111111111111111'
    ;;
  submodule\ *)
    ;;
  *)
    echo "unexpected git invocation: $*" >&2
    exit 64
    ;;
esac
STUB
  chmod +x "$bin_dir/git"

  cat > "$bin_dir/blacksmith" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CMUX_BLACKSMITH_LOG"
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' 'blacksmith version fixture'
  exit 0
fi
if [[ "${1:-}" == "auth" && "${2:-}" == "whoami" ]]; then
  exit 0
fi
if [[ "${1:-}" != "testbox" ]]; then
  echo "unexpected blacksmith invocation: $*" >&2
  exit 64
fi
  case "${2:-}" in
  list)
    if [[ "$CMUX_TEST_MODE" == "preflight-fails" ]]; then
      echo 'simulated pre-dispatch inventory failure' >&2
      exit 17
    fi
    printf '%s\n' 'ID STATUS REPO WORKFLOW JOB REF CREATED'
    printf '%s\n' 'tbx_existing ready cmux .github/workflows/cmux-tui-testbox-warmup.yml cmux-tui-rust main 2026-09-03T00:00:00Z'
    ;;
  warmup)
    if [[ "$CMUX_TEST_MODE" == "interrupt-warmup" ]]; then
      printf 'Testbox ID: %s\n' "$CMUX_TESTBOX_ID"
      : > "$CMUX_WARMUP_STARTED"
      while [[ ! -e "$CMUX_WARMUP_RELEASE" ]]; do
        /bin/sleep 1
      done
      exit 0
    fi
    if [[ "$CMUX_TEST_MODE" == "failed-warmup" ]]; then
      # A failed CLI transcript can contain an identifier from an earlier
      # attempt. The demo must not adopt it for cleanup ownership.
      printf '%s\n' 'Testbox ID: tbx_stale_transcript_99'
      printf '%s\n' 'warmup failed after a stale Testbox ID' >&2
      exit 23
    fi
    if [[ "$CMUX_TEST_MODE" == "partial-warmup" || "$CMUX_TEST_MODE" == "preflight-fails" ]]; then
      # The dispatch created this box before the CLI connection failed. The
      # demo may stop it only after an exact status lookup proves the ID is
      # present now and absent from the pre-dispatch inventory.
      printf 'Testbox ID: %s\n' "$CMUX_TESTBOX_ID"
      printf '%s\n' 'warmup connection failed after dispatch' >&2
      exit 23
    fi
    printf 'Testbox ID: %s\n' "$CMUX_TESTBOX_ID"
    ;;
  status)
    calls="$(cat "$CMUX_STATUS_CALLS")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" > "$CMUX_STATUS_CALLS"
    requested_id=""
    previous=""
    for arg in "$@"; do
      if [[ "$previous" == "--id" ]]; then
        requested_id="$arg"
      fi
      previous="$arg"
    done
    if [[ "$CMUX_TEST_MODE" == "failed-warmup" && "$requested_id" != "$CMUX_TESTBOX_ID" ]]; then
      echo 'testbox not found' >&2
      exit 1
    fi
    if [[ "$CMUX_TEST_MODE" == "partial-warmup" && "$requested_id" != "$CMUX_TESTBOX_ID" ]]; then
      echo 'unexpected partial warmup lookup' >&2
      exit 1
    fi
    printf '%s\n' 'ID STATUS IP WORKFLOW JOB REF CREATED RUN URL'
    run_url=""
    if [[ "$CMUX_TEST_MODE" == "ambiguous" ]]; then
      run_url='https://github.com/manaflow-ai/cmux/actions/runs/3003'
    elif [[ "$CMUX_TEST_MODE" == "no-approve" || "$CMUX_TEST_MODE" == "stop-fails" || "$CMUX_TEST_MODE" == "stop-and-cancel-fails" ]]; then
      # The no-approve case must use the exact RUN URL from its Testbox row.
      run_url='https://github.com/manaflow-ai/cmux/actions/runs/2002'
    elif [[ "$CMUX_TEST_MODE" == "pre-ready-stop-fails" ]]; then
      # Approval fails before the ready phase starts. Cleanup must perform one
      # exact, non-waiting status lookup before the stop fallback.
      run_url='https://github.com/manaflow-ai/cmux/actions/runs/5005'
    elif [[ "$CMUX_TEST_MODE" == "interrupt-warmup" ]]; then
      run_url='https://github.com/manaflow-ai/cmux/actions/runs/6006'
    elif [[ "$CMUX_TEST_MODE" == "delayed" && "$calls" -ge 2 ]]; then
      # The first status response is URL-free. Reconciliation must use the
      # native bounded wait and observe this later authoritative row.
      run_url='https://github.com/manaflow-ai/cmux/actions/runs/4004'
    fi
    if [[ -n "$run_url" ]]; then
      printf '%s\n' "${CMUX_TESTBOX_ID} ready 127.0.0.1 .github/workflows/cmux-tui-testbox-warmup.yml cmux-tui-rust main 2026-09-03T00:00:00Z $run_url"
    else
      # Leave this row URL-free to prove that cleanup fails closed.
      printf '%s\n' "${CMUX_TESTBOX_ID} ready 127.0.0.1 .github/workflows/cmux-tui-testbox-warmup.yml cmux-tui-rust main 2026-09-03T00:00:00Z"
    fi
    ;;
  stop)
    if [[ "$CMUX_TEST_MODE" == "stop-fails" || "$CMUX_TEST_MODE" == "stop-and-cancel-fails" || "$CMUX_TEST_MODE" == "pre-ready-stop-fails" ]]; then
      echo 'simulated stop failure' >&2
      exit 42
    fi
    # Model Blacksmith's documented contract: stopping a Testbox also ends
    # the underlying warmup workflow run.
    printf '%s\n' "$CMUX_TESTBOX_ID" > "$CMUX_STOP_LOG"
    ;;
  run)
    ;;
  *)
    echo "unexpected blacksmith testbox invocation: $*" >&2
    exit 64
    ;;
esac
STUB
  chmod +x "$bin_dir/blacksmith"

  cat > "$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
  if [[ "${1:-}" == "run" && "${2:-}" == "cancel" ]]; then
  printf '%s\n' "${3:-}" > "$CMUX_CANCEL_LOG"
  if [[ "$CMUX_TEST_MODE" == "stop-and-cancel-fails" ]]; then
    echo 'simulated run cancellation failure' >&2
    exit 43
  fi
  exit 0
fi
if [[ "${1:-}" != "api" ]]; then
  echo "unexpected gh invocation: $*" >&2
  exit 64
fi
endpoint="${2:-}"
if [[ "$endpoint" == "-X" ]]; then
  endpoint="${4:-}"
fi
case "$endpoint" in
  *'status=waiting'*)
    calls="$(cat "$CMUX_WAITING_CALLS")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" > "$CMUX_WAITING_CALLS"
    if (( calls == 1 )); then
      printf '%s\n' '1001'
    elif [[ "$CMUX_TEST_MODE" == "ambiguous" || "$CMUX_TEST_MODE" == "ambiguous-unresolved" || "$CMUX_TEST_MODE" == "ambiguous-approval-unresolved" ]]; then
      printf '%s\n' '1001' '2002' '3003'
    else
      printf '%s\n' '1001' '2002'
    fi
    ;;
  *pending_deployments*)
    run_id_from_endpoint="$(printf '%s\n' "$endpoint" | sed -nE 's#^.*/runs/([0-9]+)/pending_deployments$#\1#p')"
    printf '%s\n' "$run_id_from_endpoint" > "$CMUX_APPROVAL_LOG"
    if [[ "$CMUX_TEST_MODE" == "pre-ready-stop-fails" ]]; then
      echo 'simulated approval lookup failure' >&2
      exit 17
    fi
    printf '%s\n' '42'
    ;;
  *actions/runs/*)
    printf '%s\n' 'in_progress pending'
    ;;
  *)
    echo "unexpected gh API endpoint: $endpoint" >&2
    exit 64
    ;;
esac
STUB
  chmod +x "$bin_dir/gh"

  cat > "$bin_dir/mktemp" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count_file="$CMUX_CASE_ROOT/mktemp-count"
count=0
if [[ -s "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
path="$CMUX_CASE_ROOT/temp-$count"
: > "$path"
printf '%s\n' "$path" >> "$CMUX_MKTEMP_LOG"
printf '%s\n' "$path"
STUB
  chmod +x "$bin_dir/mktemp"

  cat > "$bin_dir/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$bin_dir/sleep"

  set +e
  if [[ "$mode" == "interrupt-warmup" ]]; then
    CMUX_CASE_ROOT="$case_root" \
      CMUX_TEST_MODE="$mode" \
      CMUX_TESTBOX_ID="$testbox_id" \
      CMUX_BLACKSMITH_LOG="$case_root/blacksmith.log" \
      CMUX_BOUNDED_LOG="$bounded_log" \
      CMUX_CANCEL_LOG="$cancel_log" \
      CMUX_APPROVAL_LOG="$approval_log" \
      CMUX_STOP_LOG="$stop_log" \
      CMUX_MKTEMP_LOG="$mktemp_log" \
      CMUX_STATUS_CALLS="$status_calls" \
      CMUX_WAITING_CALLS="$waiting_calls" \
      CMUX_WARMUP_STARTED="$warmup_started" \
      CMUX_WARMUP_RELEASE="$warmup_release" \
      PATH="$bin_dir:/usr/bin:/bin" \
      "$case_root/scripts/blacksmith-testbox-demo.sh" --no-approve >"$output" 2>&1 &
    demo_pid=$!
    for _ in $(seq 1 100); do
      [[ -e "$warmup_started" ]] && break
      /bin/sleep 0.1
    done
    if ! [[ -e "$warmup_started" ]]; then
      kill -TERM "$demo_pid" 2>/dev/null || true
      : >"$warmup_release"
      wait "$demo_pid" 2>/dev/null || true
      cat "$output" >&2
      echo "FAIL: interrupt fixture did not reach warmup" >&2
      exit 1
    fi
    kill -TERM "$demo_pid" 2>/dev/null || true
    : >"$warmup_release"
    wait "$demo_pid"
  elif [[ -n "$option" ]]; then
    CMUX_CASE_ROOT="$case_root" \
      CMUX_TEST_MODE="$mode" \
      CMUX_TESTBOX_ID="$testbox_id" \
      CMUX_BLACKSMITH_LOG="$case_root/blacksmith.log" \
      CMUX_BOUNDED_LOG="$bounded_log" \
      CMUX_CANCEL_LOG="$cancel_log" \
      CMUX_APPROVAL_LOG="$approval_log" \
      CMUX_STOP_LOG="$stop_log" \
      CMUX_MKTEMP_LOG="$mktemp_log" \
      CMUX_STATUS_CALLS="$status_calls" \
      CMUX_WAITING_CALLS="$waiting_calls" \
      CMUX_WARMUP_STARTED="$warmup_started" \
      CMUX_WARMUP_RELEASE="$warmup_release" \
      PATH="$bin_dir:/usr/bin:/bin" \
      "$case_root/scripts/blacksmith-testbox-demo.sh" "$option" >"$output" 2>&1
  else
    CMUX_CASE_ROOT="$case_root" \
      CMUX_TEST_MODE="$mode" \
      CMUX_TESTBOX_ID="$testbox_id" \
      CMUX_BLACKSMITH_LOG="$case_root/blacksmith.log" \
      CMUX_BOUNDED_LOG="$bounded_log" \
      CMUX_CANCEL_LOG="$cancel_log" \
      CMUX_APPROVAL_LOG="$approval_log" \
      CMUX_STOP_LOG="$stop_log" \
      CMUX_MKTEMP_LOG="$mktemp_log" \
      CMUX_STATUS_CALLS="$status_calls" \
      CMUX_WAITING_CALLS="$waiting_calls" \
      CMUX_WARMUP_STARTED="$warmup_started" \
      CMUX_WARMUP_RELEASE="$warmup_release" \
      PATH="$bin_dir:/usr/bin:/bin" \
      "$case_root/scripts/blacksmith-testbox-demo.sh" >"$output" 2>&1
  fi
  local status=$?
  set -e
  if (( status != expected_status )); then
    cat "$output" >&2
    echo "FAIL: $mode case exited $status, expected $expected_status" >&2
    exit 1
  fi

  if (( expected_status == 0 )); then
    if [[ -n "$expected_run" ]]; then
      if [[ "$mode" == "stop-fails" || "$mode" == "stop-and-cancel-fails" || "$mode" == "pre-ready-stop-fails" ]]; then
        if [[ "$(cat "$cancel_log")" != "$expected_run" ]]; then
          cat "$output" >&2
          echo "FAIL: $mode case cancelled $(cat "$cancel_log"), expected $expected_run" >&2
          exit 1
        fi
      elif [[ -s "$cancel_log" ]]; then
        cat "$output" >&2
        echo "FAIL: $mode case explicitly cancelled $(cat "$cancel_log") after a successful Testbox stop" >&2
        exit 1
      fi
      if [[ "$mode" != "stop-fails" && "$mode" != "stop-and-cancel-fails" && "$mode" != "pre-ready-stop-fails" ]] && [[ "$(cat "$stop_log")" != "$testbox_id" ]]; then
        cat "$output" >&2
        echo "FAIL: $mode case did not use the successful Testbox stop as primary cleanup" >&2
        exit 1
      fi
      grep -Fq 'recorded exact warmup run URL' "$output" || {
        cat "$output" >&2
        echo "FAIL: $mode case did not record its exact warmup run" >&2
        exit 1
      }
    elif [[ -s "$cancel_log" ]]; then
      cat "$output" >&2
      echo "FAIL: $mode case cancelled an unbound run $(cat "$cancel_log")" >&2
      exit 1
    fi
  elif [[ "$mode" == "failed-warmup" ]]; then
    if grep -Fq 'testbox stop --id' "$blacksmith_log"; then
      cat "$output" >&2
      echo "FAIL: failed warmup adopted a stale Testbox ID for cleanup" >&2
      exit 1
    fi
    grep -Fq 'refusing to adopt a Testbox ID from failed warmup' "$output" || {
      cat "$output" >&2
      echo "FAIL: failed warmup did not reject its transcript ID" >&2
      exit 1
    }
  elif [[ "$mode" == "partial-warmup" ]]; then
    grep -Fq 'recovered Testbox after failed warmup from exact ID-specific status' "$output" || {
      cat "$output" >&2
      echo "FAIL: partial warmup did not prove its Testbox ID before cleanup" >&2
      exit 1
    }
    [[ "$(cat "$stop_log")" == "$testbox_id" ]] || {
      cat "$output" >&2
      echo "FAIL: partial warmup did not stop its verified Testbox" >&2
      exit 1
    }
  elif [[ "$mode" == "tee-fails" ]]; then
    grep -Fq 'recovered Testbox after failed warmup from exact ID-specific status' "$output" || {
      cat "$output" >&2
      echo "FAIL: tee failure did not prove its Testbox ID before cleanup" >&2
      exit 1
    }
    [[ "$(cat "$stop_log")" == "$testbox_id" ]] || {
      cat "$output" >&2
      echo "FAIL: tee failure did not stop its verified Testbox" >&2
      exit 1
    }
    grep -Fq "30 blacksmith testbox status --id $testbox_id" "$bounded_log" || {
      cat "$output" >&2
      echo "FAIL: tee failure did not bound its ownership check" >&2
      exit 1
    }
  elif [[ "$mode" == "preflight-fails" ]]; then
    if grep -Fq 'testbox stop --id' "$blacksmith_log"; then
      cat "$output" >&2
      echo "FAIL: failed preflight inventory allowed partial warmup cleanup ownership" >&2
      exit 1
    fi
    grep -Fq 'refusing to adopt a Testbox ID from failed warmup' "$output" || {
      cat "$output" >&2
      echo "FAIL: failed preflight inventory did not fail closed" >&2
      exit 1
    }
  elif [[ "$mode" == "stop-and-cancel-fails" ]]; then
    [[ "$(cat "$cancel_log")" == "$expected_run" ]] || {
      cat "$output" >&2
      echo "FAIL: stop-and-cancel failure did not target the exact run" >&2
      exit 1
    }
    grep -Fq 'cancel failed' "$output" || {
      cat "$output" >&2
      echo "FAIL: stop-and-cancel failure was not reported" >&2
      exit 1
    }
    grep -Fq "inspect Actions for this branch's warmup run" "$output" || {
      cat "$output" >&2
      echo "FAIL: stop-and-cancel failure did not provide generic recovery guidance" >&2
      exit 1
    }
  elif [[ "$mode" == "pre-ready-stop-fails" ]]; then
    [[ "$(cat "$cancel_log")" == "$expected_run" ]] || {
      cat "$output" >&2
      echo "FAIL: pre-ready stop failure did not target the exact run" >&2
      exit 1
    }
    grep -Fq '30 blacksmith testbox status --id' "$bounded_log" || {
      cat "$output" >&2
      echo "FAIL: pre-ready cleanup did not reconcile the exact Testbox row" >&2
      exit 1
    }
    if grep -Fq -- '--wait' "$bounded_log"; then
      cat "$output" >&2
      echo "FAIL: pre-ready cleanup waited on a deployment gate that cannot progress" >&2
      exit 1
    fi
  fi

  if [[ "$mode" == "interrupt-warmup" ]]; then
    grep -Fq 'recovered Testbox after failed warmup from exact ID-specific status' "$output" || {
      cat "$output" >&2
      echo "FAIL: interrupted warmup did not recover its Testbox in cleanup" >&2
      exit 1
    }
    [[ "$(cat "$stop_log")" == "$testbox_id" ]] || {
      cat "$output" >&2
      echo "FAIL: interrupted warmup did not stop its recovered Testbox" >&2
      exit 1
    }
    [[ "$(cat "$status_calls")" == "1" ]] || {
      cat "$output" >&2
      echo "FAIL: interrupted warmup did not use one exact ownership status lookup" >&2
      exit 1
    }
  fi
  while IFS= read -r temp_path; do
    [[ -n "$temp_path" ]] || continue
    if [[ -e "$temp_path" ]]; then
      echo "FAIL: $mode case leaked temporary file $temp_path" >&2
      exit 1
    fi
  done < "$mktemp_log"

  if grep -Fq "testbox stop --id $testbox_id" "$blacksmith_log"; then
    grep -Fq "30 blacksmith testbox stop --id $testbox_id" "$bounded_log" || {
      cat "$output" >&2
      echo "FAIL: $mode cleanup did not bound Testbox stop" >&2
      exit 1
    }
  fi
  if [[ "$mode" == "delayed" || "$mode" == "ambiguous-unresolved" ]]; then
    grep -Fq "30 blacksmith testbox status --id $testbox_id --wait --wait-timeout 30s" "$bounded_log" || {
      cat "$output" >&2
      echo "FAIL: $mode cleanup did not use the native bounded status wait" >&2
      exit 1
    }
  fi
  if [[ "$mode" == "stop-fails" || "$mode" == "stop-and-cancel-fails" || "$mode" == "pre-ready-stop-fails" ]]; then
    grep -Fq '30 gh run cancel' "$bounded_log" || {
      cat "$output" >&2
      echo "FAIL: $mode cleanup did not bound GitHub cancellation after stop failure" >&2
      exit 1
    }
    grep -Fq "30 gh api repos/manaflow-ai/cmux/actions/runs/$expected_run" "$bounded_log" || {
      cat "$output" >&2
      echo "FAIL: $mode cleanup did not bound final run-state lookup" >&2
      exit 1
    }
    grep -Fq 'inspect the Testbox dashboard' "$output" || {
      cat "$output" >&2
      echo "FAIL: $mode cleanup did not provide generic Testbox recovery guidance" >&2
      exit 1
    }
  elif grep -Fq '30 gh run cancel' "$bounded_log"; then
    cat "$output" >&2
    echo "FAIL: $mode cleanup explicitly cancelled after a successful Testbox stop" >&2
    exit 1
  fi

  stop_line="$(grep -n 'testbox stop --id' "$blacksmith_log" | tail -1 | cut -d: -f1 || true)"
  if [[ -n "$stop_line" ]] && awk -v start="$stop_line" \
    'NR > start && /testbox list --all/ { found=1 } END { if (found) exit 0; exit 1 }' \
    "$blacksmith_log"; then
    cat "$output" >&2
    echo "FAIL: $mode emitted an unfiltered Testbox inventory after cleanup" >&2
    exit 1
  fi

  if [[ "$mode" == "ambiguous" ]]; then
    [[ "$(cat "$approval_log")" == "3003" ]] || {
      cat "$output" >&2
      echo "FAIL: ambiguous case did not approve the exact Testbox run" >&2
      exit 1
    }
    grep -Fq 'approved the exact Testbox run' "$output" || {
      cat "$output" >&2
      echo "FAIL: ambiguous case did not report exact approval" >&2
      exit 1
    }
    grep -Fq '30 gh api repos/manaflow-ai/cmux/actions/runs/3003/pending_deployments' "$bounded_log" || {
      cat "$output" >&2
      echo "FAIL: ambiguous case did not bound the approval lookup" >&2
      exit 1
    }
    grep -Fq '30 gh api -X POST repos/manaflow-ai/cmux/actions/runs/3003/pending_deployments' "$bounded_log" || {
      cat "$output" >&2
      echo "FAIL: ambiguous case did not bound the approval request" >&2
      exit 1
    }
    grep -Fq 'recorded exact warmup run URL' "$output" || {
      echo "FAIL: ambiguous case did not resolve through the exact RUN URL" >&2
      exit 1
    }
  fi
  if [[ "$mode" == "ambiguous-unresolved" || "$mode" == "ambiguous-approval-unresolved" ]]; then
    grep -Fq 'refusing explicit run cancellation' "$output" || {
      echo "FAIL: missing RUN URL did not fail closed" >&2
      exit 1
    }
    if [[ -s "$cancel_log" ]]; then
      cat "$output" >&2
      echo "FAIL: unresolved run binding cancelled a run" >&2
      exit 1
    fi
    grep -Fq "30 blacksmith testbox status --id $testbox_id" "$bounded_log" || {
      cat "$output" >&2
      echo "FAIL: unresolved case did not bound Testbox status discovery" >&2
      exit 1
    }
    if [[ "$mode" == "ambiguous-unresolved" ]]; then
      grep -Fq "30 blacksmith testbox status --id $testbox_id --wait --wait-timeout 30s" "$bounded_log" || {
        cat "$output" >&2
        echo "FAIL: unresolved case did not use the native bounded status wait" >&2
        exit 1
      }
      grep -Fq '30 blacksmith testbox list --all' "$bounded_log" || {
        cat "$output" >&2
        echo "FAIL: unresolved case did not bound Testbox inventory discovery" >&2
        exit 1
      }
    else
      if grep -Fq -- '--wait' "$bounded_log"; then
        cat "$output" >&2
        echo "FAIL: unresolved approval waited on a gate that cannot progress" >&2
        exit 1
      fi
    fi
    if [[ "$mode" == "ambiguous-approval-unresolved" ]]; then
      [[ ! -s "$approval_log" ]] || {
        cat "$output" >&2
        echo "FAIL: ambiguous approval adopted a waiting-list run without an exact Testbox URL" >&2
        exit 1
      }
      grep -Fq 'not approved automatically' "$output" || {
        cat "$output" >&2
        echo "FAIL: ambiguous approval did not fail closed for an unresolved Testbox URL" >&2
        exit 1
      }
      if [[ "$(cat "$status_calls")" -lt 30 ]]; then
        cat "$output" >&2
        echo "FAIL: ambiguous approval did not exercise the exact-row retry path" >&2
        exit 1
      fi
    fi
  fi
  if [[ "$mode" == "ambiguous-unresolved" || "$mode" == "ambiguous-approval-unresolved" ]]; then
    grep -Fq 'testbox stop --id' "$blacksmith_log" || {
      cat "$output" >&2
      echo "FAIL: unresolved run binding did not stop the owned Testbox" >&2
      exit 1
    }
    [[ "$(cat "$stop_log")" == "$testbox_id" ]] || {
      cat "$output" >&2
      echo "FAIL: unresolved run binding did not use the successful Testbox stop" >&2
      exit 1
    }
  fi
  if [[ "$mode" == "delayed" ]]; then
    if [[ "$(cat "$status_calls")" -lt 2 ]]; then
      cat "$output" >&2
      echo "FAIL: delayed case did not retry the exact Testbox row" >&2
      exit 1
    fi
    grep -Fq 'recorded exact warmup run URL' "$output" || {
      cat "$output" >&2
      echo "FAIL: delayed case did not record the later exact RUN URL" >&2
      exit 1
    }
  fi
  if [[ "$mode" == "ambiguous" ]]; then
    if [[ "$(cat "$status_calls")" != "2" ]]; then
      cat "$output" >&2
      echo "FAIL: ambiguous approval did not use exact status reconciliation" >&2
      exit 1
    fi
  elif [[ "$mode" == "no-approve" || "$mode" == "stop-fails" || "$mode" == "stop-and-cancel-fails" || "$mode" == "pre-ready-stop-fails" ]]; then
    if [[ "$(cat "$status_calls")" != "1" ]]; then
      cat "$output" >&2
      echo "FAIL: $mode queried status before the deployment gate phase" >&2
      exit 1
    fi
  fi

  if grep -Eq 'Stopping the box this script created \(tbx_|Cancelling the warmup run this script owns after stop failure \([0-9]|stop it by hand: blacksmith|cancel it by hand: gh run|could not bind Testbox tbx_' "$output"; then
    cat "$output" >&2
    echo "FAIL: $mode cleanup exposed a provider identifier or manual command" >&2
    exit 1
  fi
  if grep -Fq 'tbx_existing ready cmux' "$output"; then
    cat "$output" >&2
    echo "FAIL: $mode printed the complete pre-dispatch Testbox inventory" >&2
    exit 1
  fi
  if [[ ("$mode" == "no-approve" || "$mode" == "ambiguous" || "$mode" == "ambiguous-approval-unresolved" || "$mode" == "stop-fails" || "$mode" == "stop-and-cancel-fails" || "$mode" == "delayed") && "$(cat "$waiting_calls")" != "0" ]]; then
    cat "$output" >&2
    echo "FAIL: $mode queried the waiting-run list instead of using the Testbox RUN URL" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$mode"
}

run_case no-approve --no-approve 2002
run_case ambiguous '' 3003
run_case ambiguous-unresolved --no-approve '' 1
run_case ambiguous-approval-unresolved '' '' 1
run_case delayed --no-approve 4004
run_case failed-warmup '' '' 23
run_case partial-warmup --no-approve '' 23
run_case tee-fails --no-approve '' 19
run_case interrupt-warmup --no-approve '' 0
run_case preflight-fails --no-approve '' 23
run_case stop-fails --no-approve 2002
run_case stop-and-cancel-fails --no-approve 2002 1
run_case pre-ready-stop-fails '' 5005 17
