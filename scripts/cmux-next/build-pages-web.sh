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
icon-picker
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
glass-parity
task-manager
skills
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
SPLIT_STRINGS="settings home-channels"
# Pages that also carry a subset of the agent pane's table (generated/pane-strings.json, for the
# pane rows they reuse): it ships the same way, as pane-locales/<locale>.js into __cmuxPaneStrings.
SPLIT_PANE_STRINGS="home-channels"
# Pages kept unpacked (pack-pages.mjs --keep): the first window's, and onboarding (a first launch's).
UNPACKED_PAGES="home-channels,sidebar-chats,setup-card,onboarding"
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
if [ -n "${CMUX_ARTIFACT_RUNTIME_METAFILE:-}" ]; then export CMUX_ARTIFACT_RUNTIME_METAFILE; fi
# ci-oops fault isolation (scripts/ci/oops/isolate.py): on a pull request build only, a page that
# optional-units.json lists and that alone fails to bundle is left out and the rest is bundled again;
# the job prints a CI_OOPS line for its follow-up. Every other build runs the bundler as it is.
python3 "$ROOT/scripts/ci/oops/isolate.py" run --kind webview-page --dropped-out "$WORK/oops-dropped" -- \
  bun scripts/pages/bundle.mjs "$WORK" $PAGES
if [ -s "$WORK/oops-dropped" ]; then
  kept=""
  for page in $PAGES; do grep -qxF "$page" "$WORK/oops-dropped" || kept="$kept $page"; done
  PAGES="$kept"
fi
[ -s "$WORK/__shared/page-base.css" ] || { echo "error: pages builder did not emit __shared/page-base.css" >&2; exit 1; }
if [ -n "${CMUX_PAGES_METAFILE:-}" ]; then cp "$WORK/metafile.json" "$CMUX_PAGES_METAFILE"; fi
for page in $PAGES; do
  src="$ROOT/webviews/src/pages/$page"
  mkdir -p "$WORK/$page"
  loader=""
  case " $SPLIT_STRINGS " in
    *" $page "*) loader="$(bun scripts/pages/split-strings.mjs "$src/generated/strings.json" "$WORK/$page/locales")" ;;
  esac
  case " $SPLIT_PANE_STRINGS " in
    *" $page "*)
      pane_loader="$(bun scripts/pages/split-strings.mjs "$src/generated/pane-strings.json" "$WORK/$page/pane-locales" __cmuxPaneStrings)"
      loader="$loader
$pane_loader" ;;
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
done
# The pages the first window never shows are stored raw-deflated and inflated in memory when a page
# asks for them (scripts/pages/pack-pages.mjs, CmuxNextPages PagePackedFile.swift; CMUX-570). Home,
# what the first window shows with it (its messages, the sidebar's chats, the setup card) and the
# first-run onboarding stay as they are, with every chunk they can load.
bun scripts/pages/pack-pages.mjs "$WORK" "$WORK/metafile.json" --keep "$UNPACKED_PAGES" $PAGES
for page in $PAGES; do
  out="$OUT_ROOT/$page/index.html"
  if [ "$MODE" = "--check" ]; then
    :
  else
    mkdir -p "$OUT_ROOT/$page"
    cp "$WORK/$page/index.html" "$out"
    # A packed page's entry is __shared/page-<page>.js; a rebuild must not leave an older app.js.
    if [ -f "$WORK/$page/app.js" ]; then
      cp "$WORK/$page/app.js" "$OUT_ROOT/$page/app.js"
    else
      rm -f "$OUT_ROOT/$page/app.js"
    fi
    for dir in locales pane-locales; do
      if [ -d "$WORK/$page/$dir" ]; then
        rm -rf "${OUT_ROOT:?}/$page/$dir"
        cp -R "$WORK/$page/$dir" "$OUT_ROOT/$page/$dir"
      fi
    done
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
  # A tree with pages left out says so: build-web-bundles.sh never stamps it or installs it (--from) into a strict build.
  rm -f "$OUT_ROOT/__oops-dropped"
  if [ -s "$WORK/oops-dropped" ]; then cp "$WORK/oops-dropped" "$OUT_ROOT/__oops-dropped"; fi
fi
[ "$MODE" = "--check" ] && echo "page bundles build"
exit 0
