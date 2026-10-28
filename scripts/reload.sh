#!/usr/bin/env bash
# SCRATCH MEASUREMENT REF ONLY (cp/lag-newterm-*): never lands. split-spring.sh builds the app with this script;
# here it fetches a finished fleet build to measure instead, so the step measures that exact binary.
# split-spring.sh --config=NAME picks it: v21 (default; chrome-parity-v2-1, job 2769005f506cef2d9a476d02),
# v11 (chrome-parity-v1-1, job 567b4a26d93aa86fdce19821) or a raw artifact sha256. LAG_NEWTERM_APP_SHA256 overrides.
set -euo pipefail
cd "$(dirname "$0")/.."
which=v21
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) which="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$which" in
  v21|debug) sha=ca70a5a7f4909d7960f2a5746dc5e690980d98a7c118d3a0baa3be057ca3237d ;;
  v11) sha=08e87f1cf727d120458dfa0c35159963cf964e31cff8d2186187f7e0f063d77f ;;
  *) sha="$which" ;;
esac
sha="${LAG_NEWTERM_APP_SHA256:-$sha}"
app="$(python3 scripts/cmux-next/fleet-app-fetch.py --sha256 "$sha" --dest "$PWD/artifacts/fleet-apps")"
echo "reload stub: fetched $app (config $which, sha256 $sha)"
echo "App path:"
echo "  $app"
