#!/usr/bin/env bash
# zig-fetch-all.sh <zig project dir>: `zig build --fetch=all` with bounded retries.
#
# zig fetches every package of the tree in parallel and does not retry, so one
# reset connection fails the whole fetch. A package that arrived stays in
# ZIG_GLOBAL_CACHE_DIR, so each retry downloads only what is still missing.
# nightly-next run 40656489166 (2026-10-28) failed twice this way on Blacksmith:
# its zig package cache was evicted, and deps.files.ghostty.org reset the
# connections ("HTTP response read failure: ConnectionResetByPeer").
#
# CMUX_ZIG_FETCH_ATTEMPTS (default 4), CMUX_ZIG_FETCH_TIMEOUT_S per attempt
# (default 120; needs `timeout`, else unbounded) and CMUX_ZIG_FETCH_BACKOFF_S
# (default 5, times the attempt number) bound the total. ZIG names the zig to
# run (default: zig on PATH), for a tree that needs another Zig than PATH's.
#
# No build fetches from a third-party host: the tree's packages come from our
# mirror first (scripts/ci/seed-zig-package-archives.sh, tag = the tree's
# directory name), and with CMUX_ZIG_MIRROR_ONLY=1 (the default when CI=true)
# Zig gets no route anywhere else, so a package missing from the mirror fails
# here, named. CMUX_ZIG_SEED=0 skips the seed.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <zig project dir>" >&2; exit 2; }
dir="$1"
attempts="${CMUX_ZIG_FETCH_ATTEMPTS:-4}"
limit="${CMUX_ZIG_FETCH_TIMEOUT_S:-120}"
backoff="${CMUX_ZIG_FETCH_BACKOFF_S:-5}"
zig="${ZIG:-zig}"
bound=()
command -v timeout >/dev/null 2>&1 && bound=(timeout "$limit")
root="$(cd "$(dirname "$0")/../.." && pwd)"
mirror_only="${CMUX_ZIG_MIRROR_ONLY:-}"
[[ -n "$mirror_only" ]] || { [[ "${CI:-}" == true ]] && mirror_only=1 || mirror_only=0; }
export CMUX_ZIG_MIRROR_ONLY="$mirror_only"
if [[ "${CMUX_ZIG_SEED:-1}" != 0 ]]; then
  cache="${ZIG_GLOBAL_CACHE_DIR:-}"
  if [[ -z "$cache" ]]; then
    cache="$("$zig" env 2>/dev/null | sed -n 's/.*global_cache_dir"\{0,1\} *[:=] *"\([^"]*\)".*/\1/p' | head -1)" || cache=""
  fi
  if [[ -n "$cache" ]]; then
    mkdir -p "$cache/p" "$cache/tmp"
    "$root/scripts/ci/seed-zig-package-archives.sh" "$cache" "$dir" || true
  fi
fi
# Mirror only: Zig's HTTP client takes these proxies and nothing listens on port 9;
# an inherited NO_PROXY/no_proxy would bypass them, so both are dropped.
proxy=(env)
if [[ "$mirror_only" == 1 ]]; then
  proxy+=(-u NO_PROXY -u no_proxy)
  for name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do proxy+=("$name=http://127.0.0.1:9"); done
fi

for ((attempt = 1; attempt <= attempts; attempt++)); do
  if (cd "$dir" && ${bound[@]+"${bound[@]}"} "${proxy[@]}" "$zig" build --fetch=all); then
    exit 0
  fi
  echo "zig build --fetch=all in $dir failed (attempt $attempt of $attempts)" >&2
  if ((attempt < attempts)); then
    # A bounded backoff between attempts, not a poll: the next attempt is the retry.
    sleep $((backoff * attempt))
  fi
done
echo "error: zig build --fetch=all in $dir failed $attempts times" >&2
if [[ "$mirror_only" == 1 ]]; then
  echo "next: mirror only: a package above is not in scripts/ci/zig-packages.lock's mirror; run scripts/ci/zig_package_mirror.py check, and mirror it (its docstring)" >&2
fi
exit 1
