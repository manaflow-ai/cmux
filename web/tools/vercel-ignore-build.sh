#!/usr/bin/env bash

# Vercel runs this from the project root, which is web/. Return 0 to skip the
# build and 1 to continue it. If Git history is incomplete, build defensively.

previous_sha="${VERCEL_GIT_PREVIOUS_SHA:-}"
current_sha="${VERCEL_GIT_COMMIT_SHA:-HEAD}"

if [[ -z "$previous_sha" ]] || ! git cat-file -e "${previous_sha}^{commit}" 2>/dev/null; then
  echo "No usable previous Vercel deployment SHA; running the build."
  exit 1
fi

# The web project reads these files outside its root during build generation.
build_inputs=(
  "."
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
