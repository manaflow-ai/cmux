#!/bin/bash
# Renders the Environment gallery states at the PR head, then the same fixtures on the base's
# Environment code, printing each PNG as base64 between markers for the caller to decode.
set -uo pipefail
root=$(pwd)
cp webviews/.env-render/manifest.json /tmp/env-manifest.json
render() {
  local tag=$1
  (cd webviews && bun run gallery:build >/tmp/gal-$tag.log 2>&1) || { tail -20 /tmp/gal-$tag.log; return 1; }
  (cd scripts/gallery-matrix && bun install --frozen-lockfile >/dev/null 2>&1; bunx playwright install chromium >/dev/null 2>&1)
  CMUX_GALLERY_IN_VM=1 bun scripts/gallery-matrix/runner.ts --manifest /tmp/env-manifest.json --gallery-dir webviews/dist/gallery --output-dir /tmp/out-$tag --engines chromium > /tmp/run-$tag.log 2>&1 || tail -30 /tmp/run-$tag.log
  for f in $(find /tmp/out-$tag -name '*.png' | sort); do echo "PNG-BEGIN $tag/$(basename $f)"; base64 -w0 "$f"; echo; echo "PNG-END"; done
}
render after
for f in chatFolders.ts EnvironmentSection.tsx ChatInspector.tsx; do cp webviews/.env-render/base/$f webviews/src/agent-session/acpmux/inspector/$f; done
render before
