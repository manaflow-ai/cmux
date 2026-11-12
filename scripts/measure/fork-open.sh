#!/usr/bin/env bash
# Fleet entry for fork-open-bench.py: Fork Conversation to a usable fork (pane made, first content,
# focused composer showing the fork) for every Fork To destination, on a small and a
# big chat, with each fork checked to open exactly one pane in the right place (Leo, 2026-11-06: "just
# the fork does what you'd expect ... just make it fast and make it work well"). Builds a tagged
# cmux-next app at this checkout (bench configuration: Release optimization with the debug.* control
# methods kept), then runs the bench. Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/fork-open.sh --ref <sha> \
#     --artifact artifacts/fork-open.json [--arg=--runs=10]
# Build options (the rest go to the bench): --app=PATH (measure this app; nothing is built),
# --config=NAME (reload.sh's build configuration, default bench), --native-arch.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="forkopen"
out="$(mktemp -d)"
reload_config=(--config bench) reload_args=() bench_args=() app=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --app=*) app="${arg#--app=}" ;;
    --native-arch) reload_args+=(--native-arch) ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
if [[ -z "$app" ]]; then
  # A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
  # from the pinned cache) and ghostty-next for the bundled cmux-tui.
  git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" "${reload_config[@]}" ${reload_args[@]+"${reload_args[@]}"} 2>&1 | tee "$out/reload.log"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "fork-open: the tagged reload printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
    exit 1
  fi
fi
mkdir -p artifacts
# A fleet step has no LaunchServices session: the bench launches the app binary directly.
CMUX_BENCH_LAUNCH=direct exec python3 scripts/cmux-next/fork-open-bench.py --app "$app" \
  --json artifacts/fork-open.json --md artifacts/fork-open.md "$@"
