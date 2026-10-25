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

# The declared version, for messages when bun itself is missing.
pin="$(sed -n '/"devEngines"/,/}/s/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/webviews/package.json" | head -n 1)"
install="curl -fsSL https://bun.sh/install | bash -s bun-v${pin:-<version>}"

command -v "$bun" >/dev/null 2>&1 || { say "error: webviews needs bun ${pin:-(see webviews/package.json devEngines)} or newer; install it: $install"; exit 1; }

# Prints the declared version and a verdict: ok (at least it, same major), old,
# major (another major: semver says it may break, so devEngines moves first) or
# nopin. major.minor.patch compare numerically, so 1.4.10 is newer than 1.4.4.
out="$(cd "$ROOT/webviews" && "$bun" -e '
const m = require("./package.json").devEngines?.packageManager;
if (!m || m.name !== "bun" || !/^\d+\.\d+\.\d+$/.test(m.version ?? "")) { console.log("- nopin"); } else {
  const parts = (v) => v.split(/[.+-]/).slice(0, 3).map((p) => parseInt(p, 10) || 0);
  const have = parts(Bun.version), need = parts(m.version);
  let verdict = have[0] !== need[0] ? "major" : "ok";
  for (let i = 1; verdict === "ok" && i < 3; i++) if (have[i] !== need[i]) { if (have[i] < need[i]) verdict = "old"; break; }
  console.log(m.version + " " + verdict);
}
' 2>/dev/null)" || out=""
want="${out% *}"
status="${out#* }"
case "$status" in
  ok) exit 0 ;;
  old)
    say "error: webviews needs bun $want or newer (devEngines in webviews/package.json); $(command -v "$bun") is bun $("$bun" --version). Install it: curl -fsSL https://bun.sh/install | bash -s bun-v$want"
    exit 1 ;;
  major)
    say "error: webviews declares bun $want (devEngines in webviews/package.json); $(command -v "$bun") is bun $("$bun" --version), another major version. Install it: curl -fsSL https://bun.sh/install | bash -s bun-v$want (or move devEngines to the new major after checking it)"
    exit 1 ;;
  nopin)
    say "error: webviews/package.json must declare devEngines.packageManager as bun with an exact version"
    exit 1 ;;
  *)
    say "error: could not read the bun version of $(command -v "$bun"); install bun ${pin:-<version>}: $install"
    exit 1 ;;
esac
