#!/bin/sh
# Fails when the bun on PATH is not the exact version that
# webviews/package.json devEngines.packageManager pins. Neither bun nor Vite+
# enforces devEngines.onFail "error" today (bun ignores the field and Vite+
# treats every onFail value as "download"), so the webviews scripts call this
# before they run bun. Install the pinned bun instead of working around it.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

command -v bun >/dev/null 2>&1 || { echo "error: bun is required for webviews" >&2; exit 1; }

want="$(cd "$ROOT/webviews" && bun -e 'const m = require("./package.json").devEngines?.packageManager; if (!m || m.name !== "bun" || !m.version) process.exit(3); console.log(m.version)')" || {
  echo "error: webviews/package.json must pin devEngines.packageManager to an exact bun version" >&2
  exit 1
}
have="$(bun --version)"
if [ "$have" != "$want" ]; then
  echo "error: webviews needs bun $want (devEngines in webviews/package.json); $(command -v bun) is bun $have" >&2
  exit 1
fi
