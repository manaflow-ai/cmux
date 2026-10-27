#!/usr/bin/env bash
# SCRATCH MEASUREMENT REF ONLY: the measured app is a finished fleet build, so no GhosttyKit is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p GhosttyKit.xcframework
touch GhosttyKit.xcframework/Info.plist
