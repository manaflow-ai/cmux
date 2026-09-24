#!/usr/bin/env bash

# Vercel runs this from the project root, which is web/. Return 0 to skip the
# build and 1 to continue it. If Git history is incomplete, build defensively.

previous_sha="${VERCEL_GIT_PREVIOUS_SHA:-}"
current_sha="${VERCEL_GIT_COMMIT_SHA:-HEAD}"

if [[ -z "$previous_sha" ]]; then
  echo "No previous Vercel deployment SHA; running the build."
  exit 1
fi

# Vercel builds from a shallow clone. main lands commits faster than that clone
# is deep, so the previously deployed commit is usually outside it and the
# comparison below has nothing to compare against. Fetch just that one commit
# before treating the gap as unknown history; `git diff` only needs both trees,
# not a connected history between them.
if ! git cat-file -e "${previous_sha}^{commit}" 2>/dev/null; then
  # Never let this hold the build open: without a terminal prompt disabled and
  # a ceiling, a stalled or credential-prompting remote would hang the ignore
  # step for the whole build timeout with nothing on stdout. Any failure here,
  # including a missing `timeout`, falls through to the build below.
  GIT_TERMINAL_PROMPT=0 timeout 60 git fetch --no-tags --no-recurse-submodules \
    --quiet --depth=1 origin "$previous_sha" 2>/dev/null || true
fi

if ! git cat-file -e "${previous_sha}^{commit}" 2>/dev/null; then
  echo "Previous Vercel deployment SHA is unreachable; running the build."
  exit 1
fi

# Build for unknown web paths so a new production directory or configuration
# file cannot silently skip deployment. Exclude only known non-build inputs.
build_inputs=(
  "."
  ":(exclude)tests/"
  ":(exclude)e2e/"
  ":(exclude)scripts/"
  ":(exclude)README.md"
  ":(exclude)AGENTS.md"
  ":(exclude)CLAUDE.md"
  "../.vercelignore"
  "../CHANGELOG.md"
  "../config/iroh/managed-relay-catalog.json"
  "../workers/presence/src/generated/managedRelayCatalog.ts"
)

if git diff --quiet "$previous_sha" "$current_sha" -- "${build_inputs[@]}"; then
  echo "No web build inputs changed; skipping the Vercel build."
  exit 0
fi

echo "Web build inputs changed; running the Vercel build."
exit 1
