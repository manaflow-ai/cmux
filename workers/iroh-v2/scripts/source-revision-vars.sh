#!/usr/bin/env bash
# Prints the `wrangler deploy` variable flags that publish which source a Worker
# was built from. GET /v2/health reports them, and scripts/check-production-drift.ts
# compares them with main, so a production deployment can no longer silently
# predate a rule the shipped Mac app depends on (#13458).
#
# Output (one line, safe for unquoted expansion into a wrangler command):
#   --var CMUX_SOURCE_REVISION:<40-hex sha or unknown>
set -euo pipefail

# Inherited repository-selection variables could point Git at another
# repository and publish a revision this tree was not built from.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

revision="unknown"
if command -v git >/dev/null 2>&1 && git rev-parse --verify HEAD >/dev/null 2>&1; then
  revision="$(git rev-parse HEAD)"
  # A dirty tree is not a reproducible revision; publish "unknown" so the
  # drift check reports it instead of trusting a SHA the tree does not match.
  if [[ -n "$(git status --porcelain -- . 2>/dev/null)" ]]; then
    echo "warning: uncommitted changes under $(pwd); publishing CMUX_SOURCE_REVISION=unknown" >&2
    revision="unknown"
  fi
fi
case "$revision" in
  unknown|*[!0-9a-f]*) revision="unknown" ;;
esac
printf -- '--var CMUX_SOURCE_REVISION:%s\n' "$revision"
