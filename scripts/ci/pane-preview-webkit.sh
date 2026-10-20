#!/usr/bin/env bash
# Captures the cmux-next agent pane of this checkout in Playwright WebKit with the
# macOS system font, for PR previews (HQ tools/previews). Linux Chromium renders
# use stand-in fonts and a different engine, so they cannot show how the app's
# WKWebView draws a webview change; this step can, without building the app.
#
#   scripts/ci/pane-preview-webkit.sh [SCENARIO[,SCENARIO...]]
#
# Runs webviews/vite.config.acpmux-pane.mjs against the in-page mock daemon and the
# checkout's recorded turns (scripts/ci/pane-preview-capture.mjs), then writes
# pane-preview.tar: one PNG per scenario, theme and width, capture.json, and
# meta.json with the commit SHA, engine and macOS version. A cmux-ci light step
# returns it with --artifact pane-preview.tar. One job captures one commit; a
# before/after pair is two jobs, one per SHA.
set -euo pipefail

only="${1:-}"
if [ -n "$only" ] && ! [[ "$only" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]; then
  echo "pane-preview-webkit: scenarios are lowercase names separated by commas, got '$only'" >&2
  exit 2
fi
if [ "$(uname -s)" != Darwin ]; then
  echo "pane-preview-webkit: runs on a Mac only (WebKit with the system font)" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
out="$root/pane-preview"
rm -rf "$out" "$root/pane-preview.tar"
mkdir -p "$out"

(cd webviews && bun install --frozen-lockfile >/dev/null && ./node_modules/.bin/playwright install webkit >/dev/null)

status=0
node scripts/ci/pane-preview-capture.mjs --webviews "$root/webviews" --out "$out" --engine webkit \
  ${only:+--only "$only"} || status=$?

python3 -c 'import json, sys; print(json.dumps(dict(platform="Darwin", engine="webkit", font="system", head=sys.argv[1], macos=sys.argv[2], status=int(sys.argv[3]))))' \
  "$(git rev-parse HEAD)" "$(sw_vers -productVersion)" "$status" > "$out/meta.json"
tar -C "$out" -cf "$root/pane-preview.tar" .
exit "$status"
