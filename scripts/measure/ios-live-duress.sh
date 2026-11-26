#!/usr/bin/env bash
# Fleet entry for ios-live-duress.py: a Swift body edit on an always-on iOS simulator, rebuilt (the
# `ios-live swap` fallback) against patched live (`ios-live swift`), idle and under all-core load, then
# round after round of live patches on the same app with its memory sampled (ask-432404d083). It brings up
# its own ios-live slot at --ref (a pull request's head; default this checkout) in a scratch IOS_LIVE_ROOT
# and removes it at the end. Runs alone on the worker because it loads every core:
#   cmux-ci run --class exclusive --os macos --measurement --script scripts/measure/ios-live-duress.sh \
#     --ref <reviewed sha> --arg=--ref=<head sha> [--arg=--n=5] [--arg=--minutes=90]
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/ios-live-duress.py" "$@"
