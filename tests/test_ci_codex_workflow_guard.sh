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
check_contains "contains(github.event.pull_request.labels.*.name, 'codex-smoke-test')"
check_contains "allow-users: lawrencecchen"
check_contains "uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd"
check_contains "uses: actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b"
check_contains "uses: openai/codex-action@f5c0ca71642badb34c1e66321d8d85685a0fa3dc"
check_contains "sandbox: workspace-write"
check_contains "safety-strategy: drop-sudo"
check_contains "pull_request:"
check_contains "workflow_dispatch:"

echo "PASS: Codex workflow keeps the macOS runner and trigger guardrails"
