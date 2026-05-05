#!/usr/bin/env bash
# Regression coverage for CircleCI approval gating.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/circleci-trust-parameters.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*"
  exit 1
}

write_curl_stub() {
  local status="$1"
  cat > "$TMP_DIR/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$CURL_LOG"

out_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "$out_file" ]; then
  : > "$out_file"
fi

printf '%s' "$CURL_STATUS"
STUB
  chmod +x "$TMP_DIR/curl"
  export CURL_STATUS="$status"
}

run_gate() {
  local name="$1" branch="$2" repo_owner="$3" sender="$4" token="$5" expected="$6" curl_status="${7:-}"
  local out="$TMP_DIR/$name.json"
  local log="$TMP_DIR/$name.curl.log"

  : > "$log"
  export CURL_LOG="$log"
  if [ -n "$curl_status" ]; then
    write_curl_stub "$curl_status"
  fi

  env \
    PATH="$TMP_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    CURL_LOG="$log" \
    CURL_STATUS="${CURL_STATUS:-}" \
    CIRCLECI_PIPELINE_BRANCH="$branch" \
    CIRCLECI_PIPELINE_REPO_OWNER="$repo_owner" \
    CIRCLECI_PIPELINE_SENDER_LOGIN="$sender" \
    CIRCLECI_TRUSTED_GITHUB_ORG="manaflow-ai" \
    GITHUB_TOKEN="$token" \
    "$SCRIPT" "$out" > "$TMP_DIR/$name.stdout"

  grep -Fq "\"require_approval\": $expected" "$out" || {
    echo "Output:"
    cat "$out"
    fail "$name expected require_approval=$expected"
  }
}

assert_no_curl() {
  local name="$1"
  if [ -s "$TMP_DIR/$name.curl.log" ]; then
    cat "$TMP_DIR/$name.curl.log"
    fail "$name should not call GitHub"
  fi
}

assert_curl_contains() {
  local name="$1" expected="$2"
  grep -Fq "$expected" "$TMP_DIR/$name.curl.log" || {
    cat "$TMP_DIR/$name.curl.log"
    fail "$name missing curl argument: $expected"
  }
}

if [ ! -x "$SCRIPT" ]; then
  fail "missing executable $SCRIPT"
fi

run_gate main main external-repo outsider "" false
assert_no_curl main

run_gate org_branch feature manaflow-ai outsider "" false
assert_no_curl org_branch

run_gate private_member feature outsider-fork alice secret false 204
assert_curl_contains private_member "https://api.github.com/orgs/manaflow-ai/members/alice"

run_gate public_member feature outsider-fork alice "" false 204
assert_curl_contains public_member "https://api.github.com/orgs/manaflow-ai/public_members/alice"

run_gate non_member feature outsider-fork mallory secret true 404
assert_curl_contains non_member "https://api.github.com/orgs/manaflow-ai/members/mallory"

run_gate api_error feature outsider-fork alice secret true 500

run_gate missing_sender feature outsider-fork "" "" true
assert_no_curl missing_sender

echo "PASS: CircleCI approval trust gate decisions are correct"
