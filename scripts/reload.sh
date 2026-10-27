#!/usr/bin/env bash
# SCRATCH MEASUREMENT REF ONLY (cp/lag-newterm-*): never lands. split-spring.sh builds the app with this script;
# here it fetches the finished fleet build to measure instead (chrome-parity-v2-1, job 2769005f506cef2d9a476d02),
# so the step measures that exact binary. LAG_NEWTERM_APP_SHA256 overrides the artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
sha="${LAG_NEWTERM_APP_SHA256:-ca70a5a7f4909d7960f2a5746dc5e690980d98a7c118d3a0baa3be057ca3237d}"
app="$(python3 scripts/cmux-next/fleet-app-fetch.py --sha256 "$sha" --dest "$PWD/artifacts/fleet-apps")"
echo "reload stub: fetched $app"
echo "App path:"
echo "  $app"
