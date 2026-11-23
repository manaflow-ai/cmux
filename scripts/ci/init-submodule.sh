#!/usr/bin/env bash
# init-submodule.sh [--seed] PATH
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
#
# Before the first attempt, in CI, the submodule's git directory comes from
# the CI cache bucket when it is not on the machine yet: the exact pin
# (`submodule-gitdir-v1-<name>-<pin>`, `-` in the name written `_`), else the
# newest saved pin, so git fetches only the difference or nothing. Freestyle
# runners read github.com at about 0.3-1 MB/s (a cold 630 MB cmux checkout
# took 10-38 min there), and the ~33 MB depth-1 ghostty-next pack outran the
# 120 s bound on all three attempts of 27 of 104 cmux-next fast tier (cargo)
# jobs on 2026-11-23 (job 137511000146). INIT_SUBMODULE_CACHE_URL is the
# bucket's public URL (default https://ci-cache-next.cmux.com when
# GITHUB_ACTIONS is true; empty turns the cache off). A cache error is only
# ever a miss.
#
# --seed fills the cache: when the bucket has no entry for the exact pin, it
# fetches from the remote (no restore) and saves the git directory with the
# bucket's write credentials (r2-cache.sh save's environment).
# cmux-next-fast-tier-seed.yml runs it on every feat-cmux-next push.
set -euo pipefail

seed=false
if [[ "${1:-}" == --seed ]]; then seed=true; shift; fi
path="${1:?usage: init-submodule.sh [--seed] PATH}"
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
pin="$(git ls-files -s -- "$path" | awk '$1 == "160000" { print $2; exit }')"
url="$(git config -f .gitmodules --get "submodule.$name.url" || true)"
r2_cache="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/r2-cache.sh"
cache_url="${INIT_SUBMODULE_CACHE_URL-}"
if [[ -z "${INIT_SUBMODULE_CACHE_URL+set}" && "${GITHUB_ACTIONS:-}" == true ]]; then
  cache_url=https://ci-cache-next.cmux.com
fi
cache_prefix="submodule-gitdir-v1-${name//[^A-Za-z0-9._]/_}-"
cache_key="$cache_prefix$pin"

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

has_pin() { [[ -n "$pin" ]] && git --git-dir="$modules_dir" cat-file -e "$pin^{commit}" 2>/dev/null; }

# A git directory from the cache, or nothing. Never one this machine already
# has: a restore replaces the directory, and a populated one fetches less.
cache_hit=false
restore_gitdir() {
  [[ -n "$cache_url" && -n "$pin" && -f "$r2_cache" ]] || return 0
  [[ -e "$modules_dir" ]] && return 0
  local t0 out
  # The saved config names the work tree (core.worktree); git refuses a git
  # directory whose work tree is missing.
  mkdir -p "$path"
  t0="$(date +%s)"
  out="$(CI_CACHE_R2_PUBLIC_URL="$cache_url" CI_CACHE_R2_NAMESPACE=any GITHUB_OUTPUT= \
    bash "$r2_cache" restore "$modules_dir" "$cache_key" "$cache_prefix" 2>&1)" || true
  if [[ -d "$modules_dir" ]] && git --git-dir="$modules_dir" rev-parse --git-dir >/dev/null 2>&1; then
    # The origin is the one .gitmodules names, whatever the saving run had.
    [[ -z "$url" ]] || git --git-dir="$modules_dir" config remote.origin.url "$url"
    has_pin && cache_hit=true
    echo "init-submodule: $path git directory from the cache in $(( $(date +%s) - t0 )) s ($(tail -1 <<<"$out"); pin present: $cache_hit)"
  else
    rm -rf "$modules_dir"
    echo "init-submodule: no cached $path git directory ($(tail -1 <<<"$out")); fetching from $url"
  fi
}

save_gitdir() {
  [[ "$seed" == true ]] || return 0
  has_pin || { echo "::error::the $path git directory lacks the pin ${pin:-?}; nothing saved" >&2; return 1; }
  CI_CACHE_R2_PUBLIC_URL="$cache_url" CI_CACHE_R2_NAMESPACE=any GITHUB_OUTPUT= \
    bash "$r2_cache" save "$modules_dir" "$cache_key"
}

if [[ "$seed" == true ]]; then
  [[ -n "$cache_url" && -n "$pin" ]] || { echo "init-submodule: --seed needs a cache URL and a pinned $path" >&2; exit 2; }
  for extension in tar.zst tar.gz; do
    if curl --fail --silent --head --location --connect-timeout 15 --max-time 60 \
        "${cache_url%/}/v1/any/objects/$cache_key.$extension" >/dev/null; then
      echo "init-submodule: the cache already holds $cache_key.$extension"
      exit 0
    fi
  done
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET; do
    [[ -n "${!var:-}" ]] || { echo "init-submodule: --seed needs $var (the bucket's write credentials)" >&2; exit 2; }
  done
else
  restore_gitdir
fi

attempt=1
while :; do
  started="$(date +%s)"
  status=0
  # The +-expansion keeps an empty array legal under set -u in bash 3.2.
  ${timeout_cmd[@]+"${timeout_cmd[@]}"} git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
    submodule update --init --depth 1 -- "$path" || status=$?
  if [[ "$status" -eq 0 ]]; then
    echo "init-submodule: $path at ${pin:0:12} in $(( $(date +%s) - started )) s (attempt $attempt)"
    save_gitdir || exit $?
    exit 0
  fi
  if (( attempt >= attempts )); then
    echo "::error::git submodule update for $path failed $attempt times (last exit $status, $(( $(date +%s) - started )) s)" >&2
    exit "$status"
  fi
  delay="${backoff[attempt - 1]:-${backoff[${#backoff[@]} - 1]:-0}}"
  echo "::warning::git submodule update for $path failed (attempt $attempt of $attempts, exit $status); retrying in ${delay}s" >&2
  reset_submodule
  sleep "$delay"
  attempt=$((attempt + 1))
done
