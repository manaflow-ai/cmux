#!/bin/bash
set -euo pipefail

SOURCE_ROOT="${1:?source checkout is required}"
PATCH_FILE="${2:?patch file is required}"
PATCH_FILE="$(cd "$(dirname "$PATCH_FILE")" && pwd)/$(basename "$PATCH_FILE")"

if git -C "$SOURCE_ROOT" apply --check "$PATCH_FILE" 2>/dev/null; then
  git -C "$SOURCE_ROOT" apply "$PATCH_FILE"
elif git -C "$SOURCE_ROOT" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
  # The source may be shared with another build that already applied the same
  # immutable cmux-side patch. Keep the operation idempotent.
  exit 0
else
  echo "error: cmux-cua patch does not apply cleanly: $PATCH_FILE" >&2
  exit 1
fi
