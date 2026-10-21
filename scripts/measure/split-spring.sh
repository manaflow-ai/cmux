#!/usr/bin/env bash
# Fleet entry for the rapid Cmd-D / Cmd-Shift-D run (split-spring): builds a tagged cmux-next app at this
# checkout, then runs scripts/cmux-next/split-spring-terminal.py against it (five splits 100 ms apart
# from one terminal with scrollback, optionally streaming; missed frames, frame intervals, layout work,
# grids sent to the PTY owner, hangs). Needs a logged-in console (an owned mini).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \
#     --ref <sha> --artifact artifacts/split-spring/report.json [--arg=--rounds=3] [--arg=--stream] [--arg=--gate]
# To time an older commit, revert the change on a scratch ref of the tip (the script blob must match the reviewed one).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
tag="split-spring"
out="$(pwd)/artifacts/split-spring"
mkdir -p "$out"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "split-spring: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/split-spring-terminal.py --tag "$tag" --app "$app" --out "$out" --json "$out/report.json" "$@"
