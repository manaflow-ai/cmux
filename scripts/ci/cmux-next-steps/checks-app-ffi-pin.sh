#!/usr/bin/env bash
# cmux-next.yml checks: "Check the app FFI pin".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
if [[ "$EVENT_NAME" != pull_request ]]; then
  exec scripts/cmux-next/check-app-ffi-pin.sh --verify-release --stale-grace 7200
fi
work="$(/usr/bin/mktemp -d "${RUNNER_TEMP:-/tmp}/app-ffi-pin.XXXXXX")"
/bin/mkdir "$work/home" "$work/code"
exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$work/home" \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 GIT_LFS_SKIP_SMUDGE=1 \
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
  GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false \
  MERGE="$GITHUB_SHA" CODE="$work/code" CHECKOUT="$PWD" /bin/bash -euo pipefail -c '
  cd "$CHECKOUT"
  [[ "$(git rev-parse HEAD)" == "$MERGE" ]] \
    || { echo "error: the checkout HEAD is not the merge commit $MERGE" >&2; exit 1; }
  base="$(git cat-file commit "$MERGE" | awk "\$1 == \"parent\" && !found { print \$2; found = 1 }")"
  base="$(git rev-parse --verify "$base^{commit}")"
  code="$CODE"
  # Why: docs/ci/cmux-next-workflow-notes/2026-11-24-checks-49.md
  mkdir -p "$code/scripts/cmux-next" "$code/scripts/ci"
  git cat-file blob "$base:scripts/cmux-next/check-app-ffi-pin.sh" >"$code/scripts/cmux-next/check-app-ffi-pin.sh"
  git cat-file blob "$base:scripts/ci/app_ffi_pin.py" >"$code/scripts/ci/app_ffi_pin.py"
  if ! grep -q -e "--tree)" "$code/scripts/cmux-next/check-app-ffi-pin.sh"; then
    # Why: docs/ci/cmux-next-workflow-notes/2026-11-24-checks-50.md
    echo "note: the base check has no --tree; the checkout copy runs"
    exec scripts/cmux-next/check-app-ffi-pin.sh --verify-release --base "$base"
  fi
  tree="$code/tree"
  git worktree add -f -f --quiet --detach "$tree" "$MERGE"
  status=0
  bash "$code/scripts/cmux-next/check-app-ffi-pin.sh" --verify-release --base "$base" --tree "$tree" || status=$?
  git worktree remove --force "$tree" || true
  exit "$status"
'
