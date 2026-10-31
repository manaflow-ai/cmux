#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Read whether the OptChat Chief was rebuilt". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
# build-optchat-chief.sh wrote whether it reused the restored entry or rebuilt it (a miss,
# or an entry that failed validation). Only a rebuilt entry is saved, as a new generation
# the next restore prefers (chief-cache-key.sh).
set -euo pipefail
result="$(cat "${CMUX_NEXT_OPTCHAT_CHIEF_RESULT_FILE:?}" 2>/dev/null || true)"
echo "optchat-chief cache: ${result:-no result}"
if [[ "$result" == built ]]; then echo "rebuilt=true" >> "$GITHUB_OUTPUT"; fi
