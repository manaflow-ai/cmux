#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

codex_bin="${CODEX_BIN:-codex}"
codex_home="${CODEX_HOME:-${RUNNER_TEMP:-/tmp}/codex-docs-home}"
subrouter_base_url="${CODEX_SUBROUTER_BASE_URL:-}"
subrouter_api_key="${CODEX_SUBROUTER_API_KEY:-}"
subrouter_account_id="${SUBROUTER_CODEX_ACCOUNT_ID:-}"
subrouter_user_email="${SUBROUTER_CODEX_USER_EMAIL:-}"
model="${CODEX_MODEL:-gpt-5.5}"
reasoning_effort="${CODEX_REASONING_EFFORT:-high}"
output_file="${CODEX_DOCS_OUTPUT_FILE:-${RUNNER_TEMP:-/tmp}/codex-docs-maintenance.txt}"

if [ -z "$subrouter_base_url" ]; then
  echo "::error::Set CODEX_SUBROUTER_BASE_URL to the Subrouter OpenAI-compatible /v1 endpoint."
  exit 1
fi

if [ -z "$subrouter_api_key" ]; then
  echo "::error::Set CODEX_SUBROUTER_API_KEY so Codex can authenticate through Subrouter."
  exit 1
fi

toml_string() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

mkdir -p "$codex_home"
chmod 700 "$codex_home"

{
  echo "# Written by scripts/run-daily-docs-codex.sh for scheduled docs maintenance."
  echo "model_provider = \"subrouter\""
  echo "model = $(toml_string "$model")"
  echo "model_reasoning_effort = $(toml_string "$reasoning_effort")"
  echo
  echo "[model_providers.subrouter]"
  echo "name = \"Subrouter\""
  echo "base_url = $(toml_string "$subrouter_base_url")"
  echo "wire_api = \"responses\""
  if [ -n "$subrouter_account_id" ] || [ -n "$subrouter_user_email" ]; then
    echo
    echo "[model_providers.subrouter.http_headers]"
    if [ -n "$subrouter_account_id" ]; then
      echo "X-Subrouter-Account-ID = $(toml_string "$subrouter_account_id")"
    fi
    if [ -n "$subrouter_user_email" ]; then
      echo "X-Subrouter-User-Email = $(toml_string "$subrouter_user_email")"
    fi
  fi
  echo
  echo "[projects.$(toml_string "$repo_root")]"
  echo "trust_level = \"trusted\""
} > "$codex_home/config.toml"
chmod 600 "$codex_home/config.toml"

export CODEX_HOME="$codex_home"
export OPENAI_API_KEY="$subrouter_api_key"
export CODEX_API_KEY="$subrouter_api_key"

prompt_file="${RUNNER_TEMP:-/tmp}/codex-docs-maintenance-prompt.md"
cat > "$prompt_file" <<'PROMPT'
You are running the scheduled cmux documentation maintenance pass.

Goal:
Review the repository's commit history and current product surface, then update docs where shipped behavior is missing, stale, misleading, or deserves a new docs page. If the docs are already good, leave the working tree unchanged.

Required scope:
- Inspect commit history with git. Prioritize recent main commits, but look further back when a feature appears underdocumented.
- Compare code, CLI help, changelog entries, existing docs, and web docs before editing.
- Make focused documentation changes only. Good targets include docs/*.md, README*.md, CHANGELOG.md, web docs pages, docs navigation, docs search fixtures, and localized docs message files.
- If you change web docs content, preserve the existing localization architecture. Add or update all required locale keys. Do not leave English-only user-facing strings in TSX.
- Do not edit Swift, app runtime, backend runtime, packaging, release automation, or non-doc product code.
- Do not run xcodebuild test, xcodebuild test-without-building, test-unit.sh, or local XCUITest.
- Prefer a small useful PR over broad churn. Avoid formatting-only changes.
- If you add a new docs page, wire it into docs navigation and any docs index/search expectations that need it.

At the end, summarize what you changed and why. If no docs update is warranted, say so and make no file changes.
PROMPT

if [ -n "${CODEX_DOCS_PROMPT_SUFFIX:-}" ]; then
  {
    echo
    echo "Additional operator instructions:"
    echo "$CODEX_DOCS_PROMPT_SUFFIX"
  } >> "$prompt_file"
fi

"$codex_bin" exec \
  --dangerously-bypass-approvals-and-sandbox \
  --ask-for-approval never \
  --sandbox danger-full-access \
  --cd "$repo_root" \
  --output-last-message "$output_file" \
  "$(cat "$prompt_file")"

if [ -z "$(git status --porcelain)" ]; then
  echo "Codex found no docs changes to propose."
  exit 0
fi

disallowed_paths="$(
  git status --porcelain=v1 | sed -E 's/^.. //' | sed -E 's/^.* -> //' | while IFS= read -r path; do
    case "$path" in
      CHANGELOG.md|README.md|README.*.md|docs/*|web/app/\[locale\]/docs/*|web/app/\[locale\]/components/docs-*|web/messages/*|web/tests/*docs*|web/tests/agent-page-variants.test.ts|web/tools/build-docs-search.mjs)
        ;;
      *)
        printf '%s\n' "$path"
        ;;
    esac
  done
)"

if [ -n "$disallowed_paths" ]; then
  echo "::error::Codex changed non-doc paths. Refusing to create a PR."
  printf '%s\n' "$disallowed_paths"
  git status --short
  exit 1
fi

echo "Codex produced docs changes:"
git status --short
