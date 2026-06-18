#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-.}"
cd "$repo_root"

clear_stale_locks() {
  if [ -d .git/modules ]; then
    find .git/modules -type f \
      \( -name index.lock -o -name shallow.lock -o -name config.lock -o -name packed-refs.lock \) \
      -print -delete
  fi
}

git_auth_args=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  auth_header="$(
    python3 - <<'PY'
import base64
import os

token = os.environ["GITHUB_TOKEN"]
value = base64.b64encode(f"x-access-token:{token}".encode()).decode()
print(f"AUTHORIZATION: basic {value}")
PY
  )"
  git_auth_args=(-c "http.https://github.com/.extraheader=${auth_header}")
fi

clear_stale_locks
git submodule sync --recursive

status=1
for attempt in 1 2 3; do
  if git "${git_auth_args[@]}" submodule update --init --recursive --depth=1; then
    exit 0
  fi
  status=$?
  if [ "$attempt" -eq 3 ]; then
    break
  fi
  echo "Submodule update failed on attempt $attempt; clearing stale locks and retrying" >&2
  clear_stale_locks
  sleep $((attempt * 5))
done

exit "$status"
