#!/usr/bin/env bash
# Before/after web vitals for the in-app webviews, in one run on one machine.
#
#   webviews/scripts/web-perf/webviews-ab.sh LABEL=REF [LABEL=REF ...]
#
# For each REF: a git worktree, `bun install --frozen-lockfile`, the shipped builds of the React
# pages (build-pages-web.sh), the viewer pages (vite: diff, markdown, editor) and the agent pane
# (build-agent-pane-web.sh), each with its bundle metafile; a static server per REF; then
# vitals.mjs over every page of every REF, interleaved so drift hits every REF alike.
# Pages open with `?mock`, their in-page mock host. Results land in $FAST_CHECKS_OUT (or ./web-perf-out).
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
OUT="${FAST_CHECKS_OUT:-$PWD/web-perf-out}"
RUNS="${WEB_PERF_RUNS:-5}"
PAGES="${WEB_PERF_PAGES:-settings home-messages home-channels history files feed stats keybindings bookmarks changelog apps tasks}"
WORK="$(mktemp -d)"
mkdir -p "$OUT"
cd "$ROOT"
git fetch -q origin feat-cmux-next || true

port=5100
labels=()
for pair in "$@"; do
  label="${pair%%=*}"; ref="${pair#*=}"
  case "$ref" in origin/*) git fetch -q origin "${ref#origin/}" || true ;; esac
  sha="$(git rev-parse "$ref")"
  echo "== $label = $ref ($sha)"
  tree="$WORK/tree-$label"
  git worktree add -q --detach "$tree" "$sha"
  site="$WORK/site-$label"
  mkdir -p "$site" "$OUT/$label"
  (
    cd "$tree/webviews"
    # Sparse runner checkouts: make sure the trees the builds read are present.
    bun install --frozen-lockfile >/dev/null
    CMUX_PAGES_METAFILE="$OUT/$label/pages-metafile.json" \
      "$tree/scripts/cmux-next/build-pages-web.sh" --out "$site/pages" > "$OUT/$label/pages-build.log" 2>&1 \
      || { echo "pages build failed ($label)"; tail -30 "$OUT/$label/pages-build.log"; }
    node scripts/pages/gen-strings.mjs >/dev/null 2>&1 || true
    CMUX_WEBVIEWS_OUT_DIR="$site/app" CMUX_WEBVIEWS_METAFILE="$OUT/$label/app-metafile.json" \
      ./node_modules/.bin/vp build > "$OUT/$label/app-build.log" 2>&1 \
      || { echo "viewer build failed ($label)"; tail -30 "$OUT/$label/app-build.log"; }
    CMUX_BUNDLE_REPORT_DIR="$OUT/$label/pane-report" \
      "$tree/scripts/cmux-next/build-agent-pane-web.sh" --out "$site/pane" > "$OUT/$label/pane-build.log" 2>&1 \
      || { echo "agent pane build failed ($label)"; tail -30 "$OUT/$label/pane-build.log"; }
  )
  # Every emitted script's size, for the per-chunk diff.
  (cd "$site" && find . -name '*.js' -o -name '*.mjs' | sort | xargs -r wc -c) > "$OUT/$label/files.txt" || true
  bun "$ROOT/webviews/scripts/web-perf/static-server.ts" "$site" "$port" &
  labels+=("$label:$port")
  port=$((port + 1))
done

urls=()
for page in $PAGES; do
  for lp in "${labels[@]}"; do urls+=("http://127.0.0.1:${lp#*:}/pages/$page/index.html?mock"); done
done
for viewer in markdown-page.html diff-page.html editor-page.html; do
  for lp in "${labels[@]}"; do urls+=("http://127.0.0.1:${lp#*:}/app/$viewer"); done
done
for lp in "${labels[@]}"; do urls+=("http://127.0.0.1:${lp#*:}/pane/index.html"); done
printf '%s\n' "${labels[@]}" > "$OUT/labels.txt"

cd "$ROOT/webviews"
./node_modules/.bin/playwright install chromium >/dev/null 2>&1 || npx playwright install chromium >/dev/null 2>&1 || true
node scripts/web-perf/vitals.mjs --runs "$RUNS" --out "$OUT/vitals.json" "${urls[@]}" 2>&1 | tee "$OUT/vitals.txt"
