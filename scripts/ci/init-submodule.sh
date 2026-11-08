#!/usr/bin/env bash
# init-submodule.sh PATH
#
# Run `git submodule update --init --depth 1 -- PATH` from the repository
# root, and retry a failed network fetch. A runner that cannot reach
# github.com for one window otherwise fails the job: run 38135516760 lost
# "Initialize Ghostty source submodule" to "Failed to connect to github.com
# port 443 after 134099 ms" while a second box in the same workflow cloned
# the same pin.
#
# At most INIT_SUBMODULE_ATTEMPTS (default 3) attempts. Each attempt is
# bounded by INIT_SUBMODULE_ATTEMPT_TIMEOUT seconds (default 120) when a
# `timeout` command exists (Linux, Git Bash; stock macOS has none), and by
# git's low-speed abort (under 1000 B/s for 30 s) everywhere. Between attempts
# the half-initialized submodule is removed (deinit, its git directory, its
# work tree), so the next attempt and every later check start from a clean
# state. The pause between attempts is an intentional bounded delay before
# retrying an external network call, not synchronization: 5 s, then 15 s
# (INIT_SUBMODULE_BACKOFF overrides the list). Exit status is the last
# attempt's.
set -euo pipefail

path="${1:?usage: init-submodule.sh PATH}"
attempts="${INIT_SUBMODULE_ATTEMPTS:-3}"
attempt_timeout="${INIT_SUBMODULE_ATTEMPT_TIMEOUT:-120}"
read -r -a backoff <<< "${INIT_SUBMODULE_BACKOFF:-5 15}"

cd "$(git rev-parse --show-toplevel)"

name="$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
  | awk -v p="$path" '$2 == p { sub(/^submodule\./, "", $1); sub(/\.path$/, "", $1); print $1; exit }')"
[[ -n "$name" ]] || {
  echo "init-submodule: $path is not a submodule path in .gitmodules" >&2
  exit 2
}
modules_dir="$(git rev-parse --absolute-git-dir)/modules/$name"

# GNU timeout only: Windows also ships an unrelated timeout.exe.
timeout_cmd=()
for candidate in timeout gtimeout; do
  if "$candidate" --version 2>/dev/null | grep GNU >/dev/null; then
    timeout_cmd=("$candidate" "$attempt_timeout")
    break
  fi
done

reset_submodule() {
  git submodule deinit -f -- "$path" >/dev/null 2>&1 || true
  # A failed removal (for example a file a killed Windows git child still
  # holds) must not end the retries; the next attempt reports the real error.
  rm -rf "$modules_dir" "$path" \
    || echo "::warning::could not fully remove the $path submodule state" >&2
  mkdir -p "$path" || true
}

attempt=1
while :; do
  status=0
  # The +-expansion keeps an empty array legal under set -u in bash 3.2.
  ${timeout_cmd[@]+"${timeout_cmd[@]}"} git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
    submodule update --init --depth 1 -- "$path" || status=$?
  [[ "$status" -eq 0 ]] && exit 0
  if (( attempt >= attempts )); then
    echo "::error::git submodule update for $path failed $attempt times (last exit $status)" >&2
    exit "$status"
  fi
  delay="${backoff[attempt - 1]:-${backoff[${#backoff[@]} - 1]:-0}}"
  echo "::warning::git submodule update for $path failed (attempt $attempt of $attempts, exit $status); retrying in ${delay}s" >&2
  reset_submodule
  sleep "$delay"
  attempt=$((attempt + 1))
done
