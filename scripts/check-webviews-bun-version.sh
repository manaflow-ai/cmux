#!/bin/sh
# Fails when the bun on PATH is older than the version that
# webviews/package.json devEngines.packageManager declares. A newer patch or
# minor of the same major passes: bun is good about breaking changes, and the
# fleet should not fail a build because one host updated first. Neither bun nor
# Vite+ enforces devEngines.onFail "error" today (bun ignores the field and
# Vite+ treats every onFail value as "download"), so the webviews scripts call
# this before they run bun. This is the one bun version check; other scripts
# call it rather than comparing versions themselves.
#
# Usage: check-webviews-bun-version.sh [--quiet] [BUN]
#   --quiet  print nothing, only the exit status (callers with their own message)
#   BUN      the bun binary to check (default: bun on PATH)
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

quiet=0
if [ "${1:-}" = --quiet ]; then
  quiet=1
  shift
fi
bun="${1:-bun}"

say() { [ "$quiet" = 1 ] || echo "$@" >&2; }

# The declared version: devEngines.packageManager in webviews/package.json, read
# without bun so a broken or missing bun still gets the install command.
manager="$(sed -n '/"devEngines"/,/}/p' "$ROOT/webviews/package.json")"
want="$(printf '%s\n' "$manager" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' | head -n 1)"
name="$(printf '%s\n' "$manager" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | head -n 1)"
if [ "$name" != bun ] || ! printf '%s\n' "$want" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  say "error: webviews/package.json must declare devEngines.packageManager as bun with an exact version"
  exit 1
fi
install="curl -fsSL https://bun.sh/install | bash -s bun-v$want"

command -v "$bun" >/dev/null 2>&1 || { say "error: webviews needs bun $want or newer; install it: $install"; exit 1; }
have="$("$bun" --version 2>/dev/null || true)"

# ok (at least the pin, same major), old, major (another major: semver says it may
# break, so devEngines moves first) or unknown. major.minor.patch compare
# numerically, so 1.4.10 is newer than 1.4.4; a prerelease (1.4.4-canary.1) is
# older than its release; build metadata (+abc) is ignored.
verdict="$(printf '%s %s\n' "$have" "$want" | awk '{
  have = $1; sub(/\+.*/, "", have)
  pre = ""; if (index(have, "-")) { pre = substr(have, index(have, "-") + 1); have = substr(have, 1, index(have, "-") - 1) }
  if (have !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print "unknown"; exit }
  split(have, h, "."); split($2, w, ".")
  if (h[1] + 0 != w[1] + 0) { print "major"; exit }
  for (i = 2; i <= 3; i++) {
    if (h[i] + 0 < w[i] + 0) { print "old"; exit }
    if (h[i] + 0 > w[i] + 0) { print "ok"; exit }
  }
  if (pre == "") print "ok"; else print "old"
}')"
case "$verdict" in
  ok) exit 0 ;;
  old)
    say "error: webviews needs bun $want or newer (devEngines in webviews/package.json); $(command -v "$bun") is bun $have. Install it: $install"
    exit 1 ;;
  major)
    say "error: webviews declares bun $want (devEngines in webviews/package.json); $(command -v "$bun") is bun $have, another major version. Install it: $install (or move devEngines to the new major after checking it)"
    exit 1 ;;
  *)
    say "error: could not read the bun version of $(command -v "$bun") (${have:-no output}); install bun $want: $install"
    exit 1 ;;
esac
