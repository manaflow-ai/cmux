#!/bin/sh
# Builds the React pages (webviews/src/pages/<page>) that CmuxNextPages ships under
# Resources/pages/ (plans/cmux-next/react-pages.md), all in one esbuild run with code splitting
# (webviews/scripts/pages/build-pages.mjs): code the pages share is one set of content-hashed
# chunks under _shared/, which every page imports from cmux-page://cmux.shared/ (one URL per
# chunk), and each page's index.html preloads (modulepreload) the scripts its first frame runs and
# has no inline script. React is the shared library (_shared/react-<hash>.js), external to every
# bundle. The agent pane (CmuxNextAgentPane's Resources/agent-pane) is built by the same build in a
# run of its own, so it imports React from the same URL and changes nothing a page loads;
# build-agent-pane-web.sh writes its page around the build's output. The output is build output
# (gitignored; scripts/cmux-next/build-web-bundles.sh runs this before every app build).
#
#   scripts/cmux-next/build-pages-web.sh          # rebuild every page and the agent pane
#   scripts/cmux-next/build-pages-web.sh --check  # build into a temp dir only (fails on stale committed strings)
#   scripts/cmux-next/build-pages-web.sh --out DIR [--agent-pane PANE]
#                                                 # every page into DIR/<page>/ and DIR/_shared/,
#                                                 # the agent pane into PANE (none without it)
#
# Absorbed from the Settings lead's build-settings-web.sh (branch feat-cmux-next-settings-react).
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT_ROOT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
PANE_OUT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
MODE=build
# --out DIR writes every page (DIR/<page>/) into DIR instead (build-web-bundles.sh --out-root, checks),
# and the agent pane only where --agent-pane says.
absolute() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
OUT_GIVEN=0
PANE_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=--check ;;
    --out|--agent-pane)
      [ $# -ge 2 ] || { echo "error: $1 needs a directory" >&2; exit 2; }
      if [ "$1" = --out ]; then OUT_ROOT="$(absolute "$2")"; OUT_GIVEN=1; else PANE_OUT="$(absolute "$2")"; PANE_GIVEN=1; fi
      shift ;;
    *) echo "usage: $0 [--check] [--out DIR] [--agent-pane PANE]" >&2; exit 2 ;;
  esac
  shift
done
[ "$OUT_GIVEN" = 0 ] || [ "$PANE_GIVEN" = 1 ] || PANE_OUT=""
PAGES="history apps coderouter cloud keybindings icon-picker settings passwords changelog files stats chief-usage chief-views mobile-pairing chief-inspector home-channels debug-settings"
# Pages whose string table ships as one script per locale (locales/<locale>.js), loaded before the
# app: only English and the active locale are parsed at open (R82 first-open speed).
SPLIT_STRINGS="settings"

command -v bun >/dev/null 2>&1 || { echo "error: bun is required to build the pages" >&2; exit 1; }
"$ROOT/scripts/check-webviews-bun-version.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null

# The strings tables (the pages' and the agent pane's) are build output (#21946), made from the
# commit's catalogs; a missing translation fails, unless CMUX_STRINGS_BEST_EFFORT=1 (the autofix
# export jobs only).
bun scripts/pages/gen-strings.mjs

# Same bundler as the agent pane: React Compiler on first-party sources, then esbuild. `shiki`
# resolves to the pane's trimmed copy, for the pane and the pages that render its Markdown (code
# blocks). No CSP meta: the scheme handler sends each page's policy as a header (PageCSP, strict
# unless a first-party page widens it). A meta policy would also apply and could only narrow it. The
# builder fails when a script, preload or import of a page or of the pane's first load does not resolve.
bun scripts/pages/build-pages.mjs --out "$WORK/pages" --pages "$PAGES" --split-strings "$SPLIT_STRINGS" \
  --shiki "$ROOT/webviews/src/agent-session/acpmux/shiki" --agent-pane "$WORK/agent-scripts"
"$ROOT/scripts/cmux-next/build-agent-pane-web.sh" --scripts "$WORK/agent-scripts" --pages-tree "$WORK/pages" \
  --out "$WORK/agent-pane"

if [ "$MODE" = "--check" ]; then
  echo "page bundles and the agent pane build"
  exit 0
fi
# Only the folders this build writes are replaced, so no stale chunk stays behind and the other
# files under the output root (GENERATED.md) stay.
mkdir -p "$OUT_ROOT"
for dir in _shared $PAGES; do
  rm -rf "${OUT_ROOT:?}/$dir"
  cp -R "$WORK/pages/$dir" "$OUT_ROOT/$dir"
done
echo "wrote $OUT_ROOT: $(echo "$PAGES" | wc -w | tr -d ' ') pages, $(ls "$OUT_ROOT/_shared" | wc -l | tr -d ' ') shared chunks"
# The native interface version the bundles need (webviews/src/web-abi.json, plans/cmux-next/web-ota.md):
# the app compares a web update's abi with this copy before it serves the update.
cp "$ROOT/webviews/src/web-abi.json" "$OUT_ROOT/web-abi.json"
if [ -n "$PANE_OUT" ]; then
  # The pane's folder holds only this build's files and the placeholder (GENERATED.md).
  mkdir -p "$PANE_OUT"
  find "$PANE_OUT" -mindepth 1 -maxdepth 1 ! -name GENERATED.md -exec rm -rf {} +
  cp -R "$WORK/agent-pane/." "$PANE_OUT/"
  echo "wrote $PANE_OUT: the agent pane"
fi
