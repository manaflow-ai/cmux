#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/classify_pr_scope.py"

run_case() {
  python3 "$SCRIPT" "$@"
}

expect_line() {
  local haystack="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "FAIL: Expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

docs_only_output="$(run_case \
  --event-name pull_request \
  --path README.md \
  --path skills/cmux-browser/SKILL.md \
  --path web/app/docs/browser-automation/page.tsx)"
expect_line "$docs_only_output" "docs_only=true"
expect_line "$docs_only_output" "run_heavy_macos=false"

mixed_output="$(run_case \
  --event-name pull_request \
  --path README.md \
  --path Sources/AppDelegate.swift)"
expect_line "$mixed_output" "docs_only=false"
expect_line "$mixed_output" "run_heavy_macos=true"

push_output="$(run_case \
  --event-name push \
  --path README.md)"
expect_line "$push_output" "docs_only=true"
expect_line "$push_output" "run_heavy_macos=true"

temp_repo="$(mktemp -d)"
trap 'rm -rf "$temp_repo"' EXIT

git -C "$temp_repo" init -q
git -C "$temp_repo" config user.name "Codex"
git -C "$temp_repo" config user.email "codex@example.com"

mkdir -p "$temp_repo/docs" "$temp_repo/Sources"
printf 'base\n' > "$temp_repo/docs/guide.md"
printf 'base\n' > "$temp_repo/Sources/AppDelegate.swift"
git -C "$temp_repo" add docs/guide.md Sources/AppDelegate.swift
git -C "$temp_repo" commit -q -m "base"
base_sha="$(git -C "$temp_repo" rev-parse HEAD)"

printf 'head\n' > "$temp_repo/docs/guide.md"
git -C "$temp_repo" add docs/guide.md
git -C "$temp_repo" commit -q -m "docs"
docs_head_sha="$(git -C "$temp_repo" rev-parse HEAD)"

git_diff_docs_output="$(python3 "$SCRIPT" \
  --event-name pull_request \
  --repo-root "$temp_repo" \
  --base "$base_sha" \
  --head "$docs_head_sha")"
expect_line "$git_diff_docs_output" "docs_only=true"
expect_line "$git_diff_docs_output" "run_heavy_macos=false"

printf 'code\n' > "$temp_repo/Sources/AppDelegate.swift"
git -C "$temp_repo" add Sources/AppDelegate.swift
git -C "$temp_repo" commit -q -m "code"
code_head_sha="$(git -C "$temp_repo" rev-parse HEAD)"

git_diff_code_output="$(python3 "$SCRIPT" \
  --event-name pull_request \
  --repo-root "$temp_repo" \
  --base "$docs_head_sha" \
  --head "$code_head_sha")"
expect_line "$git_diff_code_output" "docs_only=false"
expect_line "$git_diff_code_output" "run_heavy_macos=true"

echo "PASS: docs-only PR classifier skips heavy macOS jobs only for allowed paths"
