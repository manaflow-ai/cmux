#!/bin/sh
# Builds the React pages (webviews/src/pages/<page>) that CmuxNextPages ships under
# Resources/pages/ (plans/cmux-next/react-pages.md), all in one esbuild run with code splitting
# (webviews/scripts/pages/build-pages.mjs): code the pages share is one set of content-hashed
# chunks under _shared/, which every page imports from cmux-page://cmux.shared/ (one URL per
# chunk), and each page's index.html preloads (modulepreload) the scripts its first frame runs and
# has no inline script. The output is build output (gitignored;
# scripts/cmux-next/build-web-bundles.sh runs this before every app build).
#
#   scripts/cmux-next/build-pages-web.sh          # rebuild every page
#   scripts/cmux-next/build-pages-web.sh --check  # build into a temp dir only (fails on stale committed strings)
#   scripts/cmux-next/build-pages-web.sh --out DIR  # build every page into DIR/<page>/ and DIR/_shared/
#
# Absorbed from the Settings lead's build-settings-web.sh (branch feat-cmux-next-settings-react).
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT_ROOT="$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages"
MODE=build
# --out DIR writes every page (DIR/<page>/) into DIR instead (build-web-bundles.sh --out-root, checks).
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=--check ;;
    --out)
      [ $# -ge 2 ] || { echo "error: --out needs a directory" >&2; exit 2; }
      case "$2" in /*) OUT_ROOT="$2" ;; *) OUT_ROOT="$PWD/$2" ;; esac
      shift ;;
    *) echo "usage: $0 [--check] [--out DIR]" >&2; exit 2 ;;
  esac
  shift
done
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

# The strings tables are build output (#21946), made from the commit's catalogs; a missing
# translation fails, unless CMUX_STRINGS_BEST_EFFORT=1 (the autofix export jobs only).
bun scripts/pages/gen-strings.mjs

# Same bundler as the agent pane: React Compiler on first-party sources, then esbuild. `shiki`
# resolves to the pane's trimmed copy, for the pages that render the pane's Markdown (code blocks).
# No CSP meta: the scheme handler sends each page's policy as a header (PageCSP, strict unless a
# first-party page widens it). A meta policy would also apply and could only narrow it. The
# builder fails when a script, preload or import of a page does not resolve.
bun scripts/pages/build-pages.mjs --out "$WORK/pages" --pages "$PAGES" --split-strings "$SPLIT_STRINGS" \
  --shiki "$ROOT/webviews/src/agent-session/acpmux/shiki"

if [ "$MODE" = "--check" ]; then
  echo "page bundles build"
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
