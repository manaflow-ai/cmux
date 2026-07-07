#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="$(cd "$MUX_DIR/.." && pwd)"
REQUIRE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require)
      REQUIRE="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

is_required() {
  local lang="$1"
  [[ -n "$REQUIRE" && ",$REQUIRE," == *",$lang,"* ]]
}

if [[ -n "${CMUX_MUX_BIN:-}" ]]; then
  MUX_BIN="$CMUX_MUX_BIN"
else
  (cd "$MUX_DIR" && cargo build -p mux-tui)
  MUX_BIN="$MUX_DIR/target/debug/cmux-mux"
fi

passed=0
skipped=0
failed=0

run_lang() {
  local lang="$1"
  shift
  local reason
  local status
  set +e
  reason="$("$@" check 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    if [[ "$status" -eq 127 ]]; then
      if is_required "$lang"; then
        echo "FAIL $lang: required toolchain missing: $reason"
        failed=$((failed + 1))
      else
        echo "SKIP $lang: $reason"
        skipped=$((skipped + 1))
      fi
    else
      echo "FAIL $lang: build failed: $reason"
      failed=$((failed + 1))
    fi
    return
  fi

  local session="bindings-${lang}-$$-$RANDOM"
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/cmux-mux-${lang}.XXXXXX.log")"
  "$MUX_BIN" --headless --session "$session" >"$log" 2>&1 &
  local server_pid=$!
  local socket=""
  for _ in $(seq 1 150); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "FAIL $lang: server exited before socket path"
      sed -n '1,120p' "$log" >&2 || true
      failed=$((failed + 1))
      rm -f "$log"
      return
    fi
    socket="$(sed -n 's/.*control socket at //p' "$log" | tail -n 1)"
    [[ -n "$socket" && -S "$socket" ]] && break
    sleep 0.1
  done
  if [[ -z "$socket" || ! -S "$socket" ]]; then
    echo "FAIL $lang: timed out waiting for socket"
    sed -n '1,120p' "$log" >&2 || true
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    failed=$((failed + 1))
    rm -f "$log"
    return
  fi

  if CMUX_MUX_SOCKET="$socket" "$@" run; then
    echo "PASS $lang"
    passed=$((passed + 1))
  else
    echo "FAIL $lang"
    failed=$((failed + 1))
  fi
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  rm -f "$log"
}

python_cmd() {
  case "$1" in
    check) command -v python3 >/dev/null || { echo "python3 not found"; return 127; } ;;
    run) python3 "$ROOT/mux/bindings/python/e2e.py" ;;
  esac
}

typescript_cmd() {
  case "$1" in
    check)
      command -v node >/dev/null || { echo "node not found"; return 127; }
      command -v npm >/dev/null || { echo "npm not found"; return 127; }
      (cd "$ROOT/mux/bindings/typescript" && npm ci --silent --no-audit --no-fund)
      (cd "$ROOT/mux/bindings/typescript" && npm run build --silent)
      ;;
    run) (cd "$ROOT/mux/bindings/typescript" && node dist/e2e/e2e.js) ;;
  esac
}

rust_cmd() {
  case "$1" in
    check)
      command -v cargo >/dev/null || { echo "cargo not found"; return 127; }
      (cd "$MUX_DIR" && cargo build -p cmux-mux-client --example e2e --locked)
      ;;
    run) (cd "$MUX_DIR" && cargo run -p cmux-mux-client --example e2e --locked --quiet) ;;
  esac
}

go_cmd() {
  case "$1" in
    check)
      command -v go >/dev/null || { echo "go not found"; return 127; }
      (cd "$ROOT/mux/bindings/go" && go build ./...)
      ;;
    run) (cd "$ROOT/mux/bindings/go" && go run ./cmd/e2e) ;;
  esac
}

java_cmd() {
  case "$1" in
    check)
      command -v javac >/dev/null || { echo "javac not found"; return 127; }
      command -v java >/dev/null || { echo "java not found"; return 127; }
      javac -version >/dev/null 2>&1 || { javac -version 2>&1; return 127; }
      java -version >/dev/null 2>&1 || { java -version 2>&1; return 127; }
      (cd "$ROOT/mux/bindings/java" && bash scripts/build.sh && java -cp out com.manaflow.cmux.mux.JsonTest && java -cp out com.manaflow.cmux.mux.StreamOpenTest && java -cp out com.manaflow.cmux.mux.WireCaptureTest)
      ;;
    run) (cd "$ROOT/mux/bindings/java" && java -cp out com.manaflow.cmux.mux.E2e) ;;
  esac
}

run_lang python python_cmd
run_lang typescript typescript_cmd
run_lang rust rust_cmd
run_lang go go_cmd
run_lang java java_cmd

echo "e2e: $passed passed, $skipped skipped, $failed failed"
[[ "$failed" -eq 0 ]]
