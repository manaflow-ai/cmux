#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

RULE="$TMP_DIR/rule.md"
DIFF="$TMP_DIR/pr.diff"

cat > "$RULE" <<'EOF'
# Fixture Rule

Flag changed lines containing fixture violations.
EOF

cat > "$DIFF" <<'EOF'
diff --git a/Sources/Foo.swift b/Sources/Foo.swift
index 1111111..2222222 100644
--- a/Sources/Foo.swift
+++ b/Sources/Foo.swift
@@ -1,3 +1,4 @@
 struct Foo {
+    func bad() { print("bad") }
 }
EOF

CLEAN='{"rule_id":"rule","violated":false,"severity":"none","summary":"clean","findings":[]}'
bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --output "$TMP_DIR/clean.json" \
  --mock-response "$CLEAN" > "$TMP_DIR/clean.out"

if ! grep -Fq '"violated": false' "$TMP_DIR/clean.out"; then
  echo "expected clean mock response to pass" >&2
  cat "$TMP_DIR/clean.out" >&2
  exit 1
fi

if ! grep -Fq '"summary": "clean"' "$TMP_DIR/clean.json"; then
  echo "expected clean JSON output file" >&2
  cat "$TMP_DIR/clean.json" >&2
  exit 1
fi

printf -v LONG_SUMMARY '%*s' 360 ''
LONG_SUMMARY="${LONG_SUMMARY// /x}"
LONG_RESPONSE="$(printf '{"rule_id":"rule","violated":true,"severity":"failure","summary":"%s","findings":[]}' "$LONG_SUMMARY")"
if bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$LONG_RESPONSE" > "$TMP_DIR/long-summary.out" 2>&1; then
  echo "expected long summary failure mock response to fail" >&2
  exit 1
fi

EXPECTED_TRUNCATED_SUMMARY="$(printf '%.297s...' "$LONG_SUMMARY")"
if ! grep -Fq "\"summary\": \"$EXPECTED_TRUNCATED_SUMMARY\"" "$TMP_DIR/long-summary.out"; then
  echo "expected model summary to be truncated" >&2
  cat "$TMP_DIR/long-summary.out" >&2
  exit 1
fi

CLEAN_WITH_FINDING='{"rule_id":"rule","violated":false,"severity":"failure","summary":"clean","findings":[{"file":"Sources/Foo.swift","line":2,"excerpt":"print(\"bad\")","why":"stale finding","confidence":"high"}]}'
bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$CLEAN_WITH_FINDING" > "$TMP_DIR/clean-with-finding.out"

if ! grep -Fq '"severity": "none"' "$TMP_DIR/clean-with-finding.out"; then
  echo "expected violated false to normalize to severity none" >&2
  cat "$TMP_DIR/clean-with-finding.out" >&2
  exit 1
fi

if grep -Fq 'stale finding' "$TMP_DIR/clean-with-finding.out"; then
  echo "expected findings to be dropped when violated is false" >&2
  cat "$TMP_DIR/clean-with-finding.out" >&2
  exit 1
fi

WARNING='{"rule_id":"rule","violated":true,"severity":"warning","summary":"needs review","findings":[{"file":"Sources/Foo.swift","line":2,"excerpt":"print(\"bad\")","why":"suspicious","confidence":"medium"}]}'
bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$WARNING" > "$TMP_DIR/warning.out"

if ! grep -Fq '"severity": "warning"' "$TMP_DIR/warning.out"; then
  echo "expected warning mock response to pass without failing" >&2
  cat "$TMP_DIR/warning.out" >&2
  exit 1
fi

FAILURE='{"rule_id":"rule","violated":true,"severity":"failure","summary":"bad","findings":[{"file":"Sources/Foo.swift","line":2,"excerpt":"print(\"bad\")","why":"print in runtime code","confidence":"high"}]}'
if bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$FAILURE" > "$TMP_DIR/failure.out" 2>&1; then
  echo "expected failure mock response to fail" >&2
  exit 1
fi

if ! grep -Fq '"severity": "failure"' "$TMP_DIR/failure.out"; then
  echo "expected failure output" >&2
  cat "$TMP_DIR/failure.out" >&2
  exit 1
fi

INVALID_NONE='{"rule_id":"rule","violated":true,"severity":"none","summary":"bad severity","findings":[]}'
if bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$INVALID_NONE" > "$TMP_DIR/invalid-none.out" 2>&1; then
  echo "expected violated true with severity none to fail" >&2
  exit 1
fi

if ! grep -Fq '"severity": "failure"' "$TMP_DIR/invalid-none.out"; then
  echo "expected violated true severity none to normalize to failure" >&2
  cat "$TMP_DIR/invalid-none.out" >&2
  exit 1
fi

if LLM_DIFF_LINT_THINKING=typo bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$CLEAN" > "$TMP_DIR/invalid-thinking.out" 2>&1; then
  echo "expected invalid env thinking value to fail" >&2
  exit 1
fi

if ! grep -Fq 'invalid thinking mode: typo' "$TMP_DIR/invalid-thinking.out"; then
  echo "expected invalid thinking diagnostic" >&2
  cat "$TMP_DIR/invalid-thinking.out" >&2
  exit 1
fi

if LLM_DIFF_LINT_REASONING_EFFORT=huge bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$CLEAN" > "$TMP_DIR/invalid-reasoning.out" 2>&1; then
  echo "expected invalid env reasoning effort value to fail" >&2
  exit 1
fi

if ! grep -Fq 'invalid reasoning effort: huge' "$TMP_DIR/invalid-reasoning.out"; then
  echo "expected invalid reasoning effort diagnostic" >&2
  cat "$TMP_DIR/invalid-reasoning.out" >&2
  exit 1
fi

if bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$CLEAN" \
  --retries -1 > "$TMP_DIR/invalid-retries.out" 2>&1; then
  echo "expected invalid retry value to fail" >&2
  exit 1
fi

if ! grep -Fq 'invalid retry value: -1' "$TMP_DIR/invalid-retries.out"; then
  echo "expected invalid retry diagnostic" >&2
  cat "$TMP_DIR/invalid-retries.out" >&2
  exit 1
fi

if bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$TMP_DIR/missing.diff" \
  --output "$TMP_DIR/load-fail.json" \
  --mock-response "$CLEAN" > "$TMP_DIR/load-fail.out" 2>&1; then
  echo "expected missing diff input to fail" >&2
  exit 1
fi

if ! grep -Fq '"summary": "input load failed:' "$TMP_DIR/load-fail.json"; then
  echo "expected structured load failure JSON artifact" >&2
  cat "$TMP_DIR/load-fail.json" >&2
  exit 1
fi

MALICIOUS_RESPONSE='{"rule_id":"rule","violated":true,"severity":"failure","summary":"leak sk-1234567890abcdefghijklmnop and AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","findings":[{"file":"Sources/Foo.swift","line":2,"excerpt":"token = ya29.a0ARrdaM-example","why":"secret ghp_1234567890abcdefghijklmnop leaked","confidence":"high"}]}'
if bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$MALICIOUS_RESPONSE" > "$TMP_DIR/malicious-response.out" 2>&1; then
  echo "expected malicious failure response to fail" >&2
  exit 1
fi

if grep -Eq 'sk-1234567890abcdefghijklmnop|AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|ya29\.a0ARrdaM-example|ghp_1234567890abcdefghijklmnop' "$TMP_DIR/malicious-response.out"; then
  echo "expected model output secrets to be redacted" >&2
  cat "$TMP_DIR/malicious-response.out" >&2
  exit 1
fi

if ! grep -Eq 'sk-REDACTED|AIza-REDACTED|ya29\.REDACTED|gh_REDACTED' "$TMP_DIR/malicious-response.out"; then
  echo "expected redaction markers in malicious output" >&2
  cat "$TMP_DIR/malicious-response.out" >&2
  exit 1
fi

env -u DEEPSEEK_API_KEY bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --skip-if-missing-key > "$TMP_DIR/missing-key.out" 2>&1

if ! grep -Fq 'DEEPSEEK_API_KEY is not set' "$TMP_DIR/missing-key.out"; then
  echo "expected missing key skip notice" >&2
  cat "$TMP_DIR/missing-key.out" >&2
  exit 1
fi

env -u OPENAI_API_KEY bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --provider openai \
  --model gpt-5.3-codex \
  --skip-if-missing-key > "$TMP_DIR/missing-openai-key.out" 2>&1

if ! grep -Fq 'OPENAI_API_KEY is not set' "$TMP_DIR/missing-openai-key.out"; then
  echo "expected missing OpenAI key skip notice" >&2
  cat "$TMP_DIR/missing-openai-key.out" >&2
  exit 1
fi

if bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --max-diff-bytes 1 \
  --mock-response "$CLEAN" > "$TMP_DIR/too-large.out" 2>&1; then
  echo "expected oversized diff to fail before mock response" >&2
  exit 1
fi

if ! grep -Fq 'The diff was not truncated' "$TMP_DIR/too-large.out"; then
  echo "expected oversized diff output" >&2
  cat "$TMP_DIR/too-large.out" >&2
  exit 1
fi

RESULTS_DIR="$TMP_DIR/results/llm-diff-lint-rule"
mkdir -p "$RESULTS_DIR"
cp "$TMP_DIR/clean.json" "$RESULTS_DIR/result.json"

python3 scripts/llm_diff_lint_comment.py \
  --results-dir "$TMP_DIR/results" \
  --pr-number 123 \
  --pr-url https://github.com/manaflow-ai/cmux/pull/123 \
  --diff-url https://github.com/manaflow-ai/cmux/pull/123.diff \
  --run-url https://github.com/manaflow-ai/cmux/actions/runs/456 \
  --dry-run > "$TMP_DIR/comment.md"

if ! grep -Fq '<!-- cmux-llm-diff-lint -->' "$TMP_DIR/comment.md"; then
  echo "expected stable comment marker" >&2
  cat "$TMP_DIR/comment.md" >&2
  exit 1
fi

if ! grep -Fq '| `rule` | deepseek | `deepseek-v4-pro` | passed | clean |' "$TMP_DIR/comment.md"; then
  echo "expected rule status table" >&2
  cat "$TMP_DIR/comment.md" >&2
  exit 1
fi

GEMINI_RESULT="$TMP_DIR/gemini.json"
LLM_DIFF_LINT_PROVIDER=google-vertex LLM_DIFF_LINT_MODEL=gemini-3-flash-preview bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$CLEAN" > "$GEMINI_RESULT"

mkdir -p "$TMP_DIR/results/llm-diff-lint-google-vertex-rule"
cp "$GEMINI_RESULT" "$TMP_DIR/results/llm-diff-lint-google-vertex-rule/result.json"

python3 scripts/llm_diff_lint_comment.py \
  --results-dir "$TMP_DIR/results" \
  --pr-number 123 \
  --pr-url https://github.com/manaflow-ai/cmux/pull/123 \
  --diff-url https://github.com/manaflow-ai/cmux/pull/123.diff \
  --run-url https://github.com/manaflow-ai/cmux/actions/runs/456 \
  --dry-run > "$TMP_DIR/compare-comment.md"

if ! grep -Fq 'deepseek and google-vertex agreed on all 1 compared rule(s).' "$TMP_DIR/compare-comment.md"; then
  echo "expected provider comparison summary" >&2
  cat "$TMP_DIR/compare-comment.md" >&2
  exit 1
fi

OPENAI_RESULT="$TMP_DIR/openai.json"
LLM_DIFF_LINT_PROVIDER=openai LLM_DIFF_LINT_MODEL=gpt-5.3-codex LLM_DIFF_LINT_REASONING_EFFORT=medium bun scripts/llm_diff_lint.ts \
  --rule "$RULE" \
  --diff-file "$DIFF" \
  --mock-response "$CLEAN" > "$OPENAI_RESULT"

if ! grep -Fq '"provider": "openai"' "$OPENAI_RESULT"; then
  echo "expected OpenAI provider in mock output" >&2
  cat "$OPENAI_RESULT" >&2
  exit 1
fi

if ! grep -Fq '"model": "gpt-5.3-codex"' "$OPENAI_RESULT"; then
  echo "expected Codex model in mock output" >&2
  cat "$OPENAI_RESULT" >&2
  exit 1
fi

WORKFLOW=".github/workflows/llm-diff-lint.yml"

if grep -Eq '^  pull_request:' "$WORKFLOW"; then
  echo "pull_request must not run LLM diff lint with repository secrets" >&2
  exit 1
fi

if ! grep -Fq 'workflow_dispatch:' "$WORKFLOW"; then
  echo "workflow_dispatch should allow trusted maintainers to lint an existing PR by number" >&2
  exit 1
fi

if ! grep -Fq 'pr_number:' "$WORKFLOW"; then
  echo "workflow_dispatch must require a pull request number input" >&2
  exit 1
fi

if ! grep -Fq 'EVENT_PR_NUMBER: ${{ github.event.pull_request.number || inputs.pr_number }}' "$WORKFLOW"; then
  echo "workflow_dispatch must share the numeric PR validation path" >&2
  exit 1
fi

default_checkout_count="$(grep -Fc 'ref: ${{ github.event.repository.default_branch }}' "$WORKFLOW")"
if [ "$default_checkout_count" -ne 4 ]; then
  echo "all workflow checkouts must use repository default branch, got $default_checkout_count" >&2
  exit 1
fi

if awk '/^permissions:/{flag=1;next}/^concurrency:/{flag=0}flag' "$WORKFLOW" | grep -Fq 'id-token:'; then
  echo "top-level id-token permission must stay disabled" >&2
  exit 1
fi

id_token_count="$(grep -Fc 'id-token: write' "$WORKFLOW")"
if [ "$id_token_count" -ne 1 ]; then
  echo "expected id-token: write only on the Google Vertex job, got $id_token_count" >&2
  exit 1
fi

if grep -Fq 'head.repo.full_name' "$WORKFLOW"; then
  echo "workflow must not checkout PR-controlled code" >&2
  exit 1
fi

if ! grep -Fq 'LLM_DIFF_LINT_CODEX_MODEL' "$WORKFLOW"; then
  echo "workflow should expose the Codex architecture model" >&2
  exit 1
fi

if ! grep -Fq 'LLM_DIFF_LINT_CODEX_REASONING_EFFORT' "$WORKFLOW"; then
  echo "workflow should expose the Codex reasoning effort" >&2
  exit 1
fi

if ! grep -Fq -- '--skip-if-missing-key' "$WORKFLOW"; then
  echo "workflow should skip the Codex rule until OPENAI_API_KEY is configured" >&2
  exit 1
fi
