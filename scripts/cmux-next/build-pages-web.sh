#!/bin/sh
# Builds React pages (webviews/src/pages/<page>) with one shared runtime/chunk graph that
# CmuxNextPages ships under Resources/pages/<page>/ (plans/cmux-next/react-pages.md). The output
# is build output (gitignored; scripts/cmux-next/build-web-bundles.sh runs this before every app build).
#
#   scripts/cmux-next/build-pages-web.sh          # rebuild every page
#   scripts/cmux-next/build-pages-web.sh --check  # build into a temp dir only (fails on stale committed strings)
#   scripts/cmux-next/build-pages-web.sh --out DIR  # build every page into DIR/<page>/
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
PAGES="
apps
artifacts
bookmarks
changelog
chief-inspector
chief-usage
chief-views
cloud
cloud-progress
coderouter
debug-settings
feed
files
github
group-editor
history
home-channels
home-messages
icon-picker
import-history
keybindings
machines
mobile-pairing
onboarding
passwords
server-cards
settings
setup-card
stash
stats
task-manager
tasks
"
# The browser chrome's pages (CmuxNextPages BrowserChromeWebHost).
PAGES="$PAGES site-settings site-data certificate"
# The Import Cookies card (BrowserCookieImportCard, through BrowserChromeWebHost).
PAGES="$PAGES cookie-import"
# The sidebar's chat history blocks (CmuxNextSidebar SidebarChatHistoryHost: one page per block shown).
PAGES="$PAGES sidebar-chats"
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

# No CSP meta: the scheme handler sends each page's policy as a header (PageCSP, strict unless a
# first-party page widens it). A meta policy would also apply and could only narrow it.
bun scripts/pages/bundle.mjs "$WORK" $PAGES
[ -s "$WORK/__shared/page-base.css" ] || { echo "error: pages builder did not emit __shared/page-base.css" >&2; exit 1; }
if [ -n "${CMUX_PAGES_METAFILE:-}" ]; then cp "$WORK/metafile.json" "$CMUX_PAGES_METAFILE"; fi
for page in $PAGES; do
  src="$ROOT/webviews/src/pages/$page"
  mkdir -p "$WORK/$page"
  loader=""
  case " $SPLIT_STRINGS " in
    *" $page "*) loader="$(bun scripts/pages/split-strings.mjs "$src/generated/strings.json" "$WORK/$page/locales")" ;;
  esac
  {
    printf '<!doctype html>\n<html lang="en" data-cmux-page="%s">\n<head>\n' "$page"
    printf '<meta charset="utf-8" />\n'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
    [ -n "$loader" ] && printf '%s\n' "$loader"
    cat "$WORK/$page/preloads.html"
    # The builder factors the exact common first-party chrome prefix into this sibling asset.
    # It stays before the page's isolated rules, preserving the original CSS cascade.
    printf '<link rel="stylesheet" href="../__shared/page-base.css" />\n'
    printf '<style>\n'
    [ -f "$WORK/$page/app.css" ] && cat "$WORK/$page/app.css"
    printf '\n</style>\n</head>\n<body>\n<main id="root"></main>\n<script type="module">\n'
    printf 'import "./app.js";\n'
    printf '\n</script>\n</body>\n</html>\n'
  } | perl -pe 's/[ \t]+$//' > "$WORK/$page/index.html"

  out="$OUT_ROOT/$page/index.html"
  if [ "$MODE" = "--check" ]; then
    :
  else
    mkdir -p "$OUT_ROOT/$page"
    cp "$WORK/$page/index.html" "$out"
    cp "$WORK/$page/app.js" "$OUT_ROOT/$page/app.js"
    if [ -d "$WORK/$page/locales" ]; then
      rm -rf "$OUT_ROOT/$page/locales"
      cp -R "$WORK/$page/locales" "$OUT_ROOT/$page/locales"
    fi
    echo "wrote $out ($(wc -c < "$out" | tr -d ' ') bytes)"
  fi
done
# The native interface version the bundles need (webviews/src/web-abi.json, plans/cmux-next/web-ota.md):
# the app compares a web update's abi with this copy before it serves the update.
if [ "$MODE" != "--check" ]; then
  mkdir -p "$OUT_ROOT"
  # This namespace contains only this builder's generated chunks. Replace it so a rebuild
  # never accumulates obsolete content hashes in the app or an OTA archive.
  rm -rf "$OUT_ROOT/__shared"
  cp -R "$WORK/__shared" "$OUT_ROOT/"
  cp "$ROOT/webviews/src/web-abi.json" "$OUT_ROOT/web-abi.json"
fi
[ "$MODE" = "--check" ] && echo "page bundles build"
exit 0
