#!/usr/bin/env bash
# Decide whether the runner-pool check should wait for declaration reconciliation.
# A history lookup or diff failure is an error: silently deferring would skip the
# live pool validation on every push.
set -euo pipefail

: "${BEFORE:?BEFORE is required}"
: "${SHA:?SHA is required}"

if ! git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
  git fetch --quiet --no-tags --depth=1 origin "$BEFORE" 2>/dev/null || {
    echo "::error title=Runner pools::unable to fetch the push's previous commit ($BEFORE)" >&2
    exit 1
  }
fi

if ! git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
  echo "::error title=Runner pools::push's previous commit is unavailable ($BEFORE)" >&2
  exit 1
fi

set +e
git diff --quiet "$BEFORE" "$SHA" -- .github/runners.json
diff_status=$?
set -e

case "$diff_status" in
  0)
    echo 'pending=false' >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
    ;;
  1)
    echo 'pending=true' >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
    echo '::notice title=Runner pools::declaration changed; scheduled reconciliation will validate the new live value'
    ;;
  *)
    echo "::error title=Runner pools::unable to compare $BEFORE to $SHA (git diff exited $diff_status)" >&2
    exit "$diff_status"
    ;;
esac
