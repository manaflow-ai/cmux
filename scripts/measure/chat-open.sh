#!/usr/bin/env bash
# Fleet entry for chat-open-bench.py: click to first content for a sidebar chat, a chat opened
# again, a subagent, a chat of thousands of turns and a chat restored after a relaunch, idle and
# under an agent-like load at default priority, at utility QoS and at nice 20 (Leo, 2026-10-29:
# "as in i want ours to load fast too :(" and "how much of this is simply putting the desktop at
# higher priority?"). Builds a tagged cmux-next app at this checkout (bench configuration: Release
# optimization with the debug.* control methods kept), then runs the bench. Runs alone on the
# worker because it launches an app and loads every core:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/chat-open.sh --ref <sha> \
#     --artifact artifacts/chat-open.json --artifact artifacts/chat-open.md [--arg=--runs=3]
# The click cases (chat-open-bench.py `click`, `click_again`) judge a sidebar click from pixels: click to first
# content frame and to final frame (--arg=--cases=click,click_again for those alone).
# Build options (the rest go to the bench):
#   --app=PATH       measure this app; nothing is built
#   --skip-build     measure the app this script last built in this checkout, when it was built at this
#                    commit with these build options (.build keeps it between steps on a worker); else build
#   --native-arch    build this Mac's architecture only (the default in a fleet measurement step)
#   --universal      build arm64 + x86_64 (CMUX_RELOAD_NATIVE_ARCH=0)
#   --derived-data=PATH  reload.sh's DerivedData (a measurement step's default is the checkout's warm
#                    .build/DerivedData/cmux-measure, so a build at a new commit is incremental)
#   --config=NAME    reload.sh's build configuration (default bench)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="chatopen"
out="$(mktemp -d)"
reload_config=(--config bench) reload_args=() bench_args=() app="" skip_build=0
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --app=*) app="${arg#--app=}" ;;
    --skip-build) skip_build=1 ;;
    --native-arch) reload_args+=(--native-arch) ;;
    --universal) export CMUX_RELOAD_NATIVE_ARCH=0 ;;
    --derived-data=*) reload_args+=(--derived-data "${arg#--derived-data=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
# The commit, configuration and architecture an app was built for: --skip-build reuses only a match.
build_id="$(git rev-parse HEAD)/${reload_config[1]}/${CMUX_RELOAD_NATIVE_ARCH:-default}/${reload_args[*]:-}"
build_id="${build_id// /,}"
# What the last build left: its commit and its app, so --skip-build reuses only an app of this commit.
last_build=".build/chat-open-last-build"
if [[ -z "$app" && "$skip_build" -eq 1 && -f "$last_build" ]]; then
  read -r built_at built_app <"$last_build" || true
  if [[ "${built_at:-}" == "$build_id" && -d "${built_app:-}" ]]; then
    app="$built_app"
    echo "chat-open: --skip-build: the app built as $build_id"
  else
    echo "chat-open: --skip-build: no app built as $build_id here (last: ${built_at:-none}); building"
  fi
elif [[ -z "$app" && "$skip_build" -eq 1 ]]; then
  echo "chat-open: --skip-build: no earlier build in this checkout; building"
fi
if [[ -n "$app" ]]; then
  if [[ ! -d "$app" ]]; then
    echo "chat-open: --app $app is not an app bundle" >&2
    exit 1
  fi
else
  # A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
  # from the pinned cache) and ghostty-next for the bundled cmux-tui.
  git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" "${reload_config[@]}" ${reload_args[@]+"${reload_args[@]}"} 2>&1 | tee "$out/reload.log"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "chat-open: the tagged reload printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
    exit 1
  fi
  mkdir -p .build
  printf '%s %s\n' "$build_id" "$app" >"$last_build"
fi
mkdir -p artifacts
# A fleet step has no LaunchServices session: the bench launches the app binary directly.
CMUX_BENCH_LAUNCH=direct exec python3 scripts/cmux-next/chat-open-bench.py --app "$app" \
  --json artifacts/chat-open.json --md artifacts/chat-open.md "$@"
