#!/bin/sh
# Builds every web bundle the cmux-next app ships, from the current sources:
# the agent pane, the React pages, Agent Activity, the palette ranker, the
# webviews app (diff, markdown and editor pages) and the Chief memory inspector.
# Every app build path runs it
# before it compiles (scripts/reload.sh, scripts/cmux-next/check-release-compile.sh,
# the macOS jobs of cmux-next.yml, the nightly-next build, nx-remote Swift test
# jobs), so a build never depends on a committed copy of the output (cx-vn5).
#
#   scripts/cmux-next/build-web-bundles.sh               # build what is stale
#   scripts/cmux-next/build-web-bundles.sh --force       # rebuild everything
#   scripts/cmux-next/build-web-bundles.sh --verify      # exit 1 if not current
#   scripts/cmux-next/build-web-bundles.sh --out-root D  # build into D (same
#                                                        # relative paths), no stamp
#   scripts/cmux-next/build-web-bundles.sh --from D      # install bundles built into D
#                                                        # for this source key, and stamp
#
# A build records the source key (web-bundle-key.py: every input file, bun's
# version) and the output digest in .web-bundles.key at the repository root
# (gitignored). The next run skips the build when both still match, so a warm
# tree costs about a second. Release and nightly builds pass --force.
#
# Needs the bun that webviews/package.json pins (scripts/check-webviews-bun-version.sh)
# and node 22.18 or newer. The fleet recipe provides both; locally:
# curl -fsSL https://bun.sh/install | bash -s bun-v<pin>
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
MODE=build
OUT_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) MODE=force ;;
    --verify) MODE=verify ;;
    --out-root)
      [ $# -ge 2 ] || { echo "error: --out-root needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT_ROOT="$2" ;; *) OUT_ROOT="$PWD/$2" ;; esac
      shift ;;
    --from)
      [ $# -ge 2 ] || { echo "error: --from needs a directory" >&2; exit 2; }
      MODE=from
      case "$2" in /*) FROM_ROOT="$2" ;; *) FROM_ROOT="$PWD/$2" ;; esac
      shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--force | --verify] [--out-root DIR] [--from DIR]" >&2; exit 2 ;;
  esac
  shift
done

# The output paths, relative to the repository root, and the builder of each.
PANE="Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
PAGES="Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
ACTIVITY="Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity"
PALETTE="Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources"
APP="Resources/markdown-viewer/webviews-app"
INSPECTOR="Native/OptChat/optchat-chief/inspector"
STAMP="$ROOT/.web-bundles.key"
KEY="$ROOT/scripts/cmux-next/web-bundle-key.py"

# CMUX_WEB_BUNDLES_TOOLS_OPTIONAL=1 (scripts/reload.sh while the bundles are
# still committed): a missing or wrong bun or node is a warning and exit 0, so
# a build log does not show an "error:" line for a build that ships the
# committed bundles. Any other failure still fails.
missing_tool() {
  if [ "${CMUX_WEB_BUNDLES_TOOLS_OPTIONAL:-0}" = 1 ]; then
    echo "warning: $1 (this build ships the committed bundles)" >&2
    exit 0
  fi
  echo "error: $1" >&2
  exit 1
}

need_bun() {
  want="$(python3 -c 'import json, sys; m = (json.load(open(sys.argv[1])).get("devEngines") or {}).get("packageManager") or {}; print(m.get("version", "") if m.get("name") == "bun" else "")' "$ROOT/webviews/package.json" 2>/dev/null || true)"
  if ! command -v bun >/dev/null 2>&1; then
    missing_tool "the cmux-next web bundles need bun ${want:-(see webviews/package.json devEngines)}; install it: curl -fsSL https://bun.sh/install | bash -s bun-v${want:-<version>}"
  fi
  if [ "${CMUX_WEB_BUNDLES_TOOLS_OPTIONAL:-0}" = 1 ] && [ -n "$want" ] && [ "$(bun --version)" != "$want" ]; then
    missing_tool "the cmux-next web bundles need bun $want; $(command -v bun) is bun $(bun --version)"
  fi
  "$ROOT/scripts/check-webviews-bun-version.sh"
  # `vp build` (the webviews app) runs on node when node is on PATH and on bun
  # otherwise, and the two emit different bytes (Vite stringifies its preload
  # helper with the runtime's Function.prototype.toString). Require node so
  # every host builds the same app; Vite+ needs node 22.18 or newer.
  if ! command -v node >/dev/null 2>&1 \
    || ! node -e 'const [a, b] = process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 18) ? 0 : 1)'; then
    missing_tool "the webviews app build needs node 22.18 or newer on PATH (found: $(command -v node >/dev/null 2>&1 && node --version || echo none))"
  fi
}

current() {
  [ -f "$STAMP" ] || return 1
  [ "$(python3 "$KEY" "$ROOT" --stamp)" = "$(cat "$STAMP")" ]
}

# --verify ignores the bun field: the Xcode phase's PATH may lack bun.
verified() {
  [ -f "$STAMP" ] || return 1
  [ "$(python3 "$KEY" "$ROOT" --verify-stamp)" = "$(cut -d' ' -f1-2 "$STAMP")" ]
}

if [ "$MODE" = verify ]; then
  if verified; then
    echo "web bundles are current"
    exit 0
  fi
  echo "error: the cmux-next web bundles are missing or stale; run scripts/cmux-next/build-web-bundles.sh" >&2
  exit 1
fi

# A tree built elsewhere for this source key (cmux-next.yml's Linux web-bundles job caches
# `--out-root` builds by `web-bundle-key.py --source`): check it is complete, install it
# and stamp it, so the build below and every later build path skip. The caller restores
# it under that key, so the stamp's source key is the key it was built from.
if [ "$MODE" = from ]; then
  # The inspector page stays committed (optchat-chief compiles it in with
  # include_str!, and the brain build runs no bundle step): never removed here.
  for path in "$PANE" "$PAGES" "$ACTIVITY" "$APP" "$PALETTE/palette-ranker.js"; do
    [ -e "$FROM_ROOT/$path" ] || { echo "error: $FROM_ROOT has no $path; build the web bundles instead" >&2; exit 1; }
  done
  rm -f "$STAMP"
  for path in "$PANE" "$PAGES" "$ACTIVITY" "$APP"; do
    rm -rf "${ROOT:?}/$path"
    mkdir -p "$(dirname "${ROOT:?}/$path")"
    cp -R "$FROM_ROOT/$path" "$ROOT/$path"
  done
  cp "$FROM_ROOT/$PALETTE/palette-ranker.js" "$ROOT/$PALETTE/palette-ranker.js"
  python3 "$KEY" "$ROOT" --stamp > "$STAMP.tmp"
  mv "$STAMP.tmp" "$STAMP"
  echo "web bundles restored ($(cut -c1-12 "$STAMP"))"
  exit 0
fi

need_bun
cd "$ROOT/webviews"
# The lockfile may have changed since node_modules was installed (a merge, a
# branch switch); a bundle built with other dependencies differs.
bun install --frozen-lockfile >/dev/null
# The strings tables are inputs of the pane and page bundles and are still
# committed. A build never writes a tracked file (cx-t3e5): a fleet or
# nx-remote build that regenerated them would ship sources no commit holds.
# A stale committed table fails the build; regenerate and commit it.
if ! bun scripts/pages/gen-strings.mjs --check; then
  echo "error: generated file is stale; run gen-strings and commit: bun webviews/scripts/pages/gen-strings.mjs (or scripts/cmux-next/regenerate-web-bundles.sh)" >&2
  exit 1
fi
cd "$ROOT"

if [ -z "$OUT_ROOT" ] && [ "$MODE" = build ] && current; then
  echo "web bundles are current ($(cut -c1-12 "$STAMP"))"
  exit 0
fi

# The memory inspector page is committed too (optchat-chief compiles it in with
# include_str!). An in-tree build checks it and never rewrites it; an
# --out-root build writes its own copy under the output root.
if [ -z "$OUT_ROOT" ] && ! "$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh" --check; then
  echo "error: generated file is stale; run scripts/cmux-next/build-optchat-inspector-web.sh and commit: $INSPECTOR/index.html" >&2
  exit 1
fi

out() {
  if [ -n "$OUT_ROOT" ]; then printf '%s/%s' "$OUT_ROOT" "$1"; else printf '%s/%s' "$ROOT" "$1"; fi
}

rm -f "$STAMP"
"$ROOT/scripts/cmux-next/build-agent-pane-web.sh" --out "$(out "$PANE")"
"$ROOT/scripts/cmux-next/build-pages-web.sh" --out "$(out "$PAGES")"
"$ROOT/scripts/cmux-next/build-agent-activity-web.sh" --out "$(out "$ACTIVITY")"
"$ROOT/scripts/cmux-next/build-palette-ranker.sh" --out "$(out "$PALETTE")"
"$ROOT/scripts/build-webviews-app.sh" --skip-checks --out "$(out "$APP")"
# In-tree, the committed page was checked above.
if [ -n "$OUT_ROOT" ]; then
  "$ROOT/scripts/cmux-next/build-optchat-inspector-web.sh" --out "$(out "$INSPECTOR")"
fi

if [ -z "$OUT_ROOT" ]; then
  python3 "$KEY" "$ROOT" --stamp > "$STAMP.tmp"
  mv "$STAMP.tmp" "$STAMP"
  echo "web bundles built ($(cut -c1-12 "$STAMP"))"
fi
