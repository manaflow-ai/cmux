#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/codex.yml"

if [ ! -f "$WORKFLOW_FILE" ]; then
  echo "FAIL: Missing workflow file at $WORKFLOW_FILE" >&2
  exit 1
fi

check_contains() {
  local needle="$1"
  if ! grep -Fq "$needle" "$WORKFLOW_FILE"; then
    echo "FAIL: Expected to find '$needle' in $WORKFLOW_FILE" >&2
    exit 1
  fi
}

check_contains "runs-on: macos-15"
check_contains "startsWith(github.event.comment.body, '@codex fix')"
check_contains "github.event.comment.user.login == 'lawrencecchen'"
check_contains "github.actor == 'lawrencecchen'"
check_contains "allow-users: lawrencecchen"
check_contains "uses: openai/codex-action@v1"
check_contains "sandbox: workspace-write"
check_contains "safety-strategy: drop-sudo"
check_contains "workflow_dispatch:"

echo "PASS: Codex workflow keeps the macOS runner and trigger guardrails"
