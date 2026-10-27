#!/usr/bin/env bash
# SCRATCH MEASUREMENT REF ONLY: never lands. scripts/measure/split-spring.sh builds the app with this script; here it
# fetches the finished fleet build of a1597bd7c687 (job b8b3952ba5dd429a7c8f523a, cmux DEV split-spring.app) instead,
# so the measurement step does not compile on the measure Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
sha=82c25400dd847bc5c155d572394225a81ac95c76477a3af48895aa4976b17273
app="$(python3 scripts/cmux-next/fleet-app-fetch.py --sha256 "$sha" --dest "$PWD/artifacts/fleet-apps")"
echo "reload stub: fetched $sha: $app"
echo "App path:"
echo "  $app"
