#!/usr/bin/env bash
# Fleet entry for pane-compile-cef.py: builds a tagged DEBUG cmux-next app at this checkout, launches it with a
# DevTools port, opens a chat and measures whether the agent pane's module code cache is consumed on a reload,
# and the pane's compile count and first contentful paint (scripts/measure/pane-compile-ab.mjs --attach).
#   cmux-ci run --class exclusive --measurement --label measure --display --script scripts/measure/pane-compile-cef.sh \
#     --ref <sha on feat-cmux-next> [--arg=--build-at=<sha>] --artifact artifacts/pane-compile-cef/runs.json [--arg=--runs=5]
# --build-at=SHA builds the app at SHA (a pull request's head: scripts/measure/app-at-commit.sh), the bench stays this checkout's:
# one step per arm of an A/B on one Mac.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/app-at-commit.sh
tag="panecompile"
out="$(pwd)/artifacts/pane-compile-cef"
mkdir -p "$out"
scratch="$(mktemp -d)"
trap 'measure_remove_scratch "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
build_at="" bench_args=()
for arg in "$@"; do
  case "$arg" in
    --build-at=*) build_at="${arg#--build-at=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
if [[ -n "$build_at" ]]; then
  app="$(CMUX_NEXT_REQUIRE_CEF=1 measure_app_at_commit "$build_at" "$tag" "$scratch/at")"
else
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
  CMUX_NEXT_REQUIRE_CEF=1 CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
fi
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "pane-compile-cef: the tagged reload printed no app path" >&2
  exit 1
fi
python3 scripts/measure/pane-compile-cef.py --app "$app" --out "$out" "$@"
