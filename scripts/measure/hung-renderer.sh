#!/usr/bin/env bash
# Fleet entry for scripts/cmux-next/hung-renderer-bench.py (hq#13463): whether a hung Chromium renderer
# freezes the window (control-socket round trips and main-thread gaps while it spins), and whether a hidden
# hung page has its renderer ended and answers again when shown (BrowserHiddenHangBound).
#
# An A/B in one step: each arm is a commit, built here as its own tagged app (bench configuration) in a
# worktree of this checkout, then measured interleaved on this host (devtools-calls.sh's build steps):
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/hung-renderer.sh --ref <reviewed sha> \
#     --arg=arms=base:<sha>,head:<sha> [--arg=--rounds=2] [--arg=--hidden-s=40] \
#     --artifact artifacts/hung-renderer.json --timeout 7200
# Without arms=, the one arm is this checkout. Other arguments go to the bench.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
root="$PWD"
arms="" bench_args=()
for arg in "$@"; do
  case "$arg" in
    arms=*) arms="${arg#arms=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
[ -n "$arms" ] || arms="this:$(git rev-parse HEAD)"
out="$(mktemp -d)"
trees=()
cleanup() {
  for tree in ${trees[@]+"${trees[@]}"}; do git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
# Steps run with a per-step HOME; the account's user-level tools (bun and node for the web bundles) live
# under its real home (as tab-switch.sh), and the step gets its own pinned bun first on PATH.
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
apps=()
# Each arm's setup (worktree, submodules, GhosttyKit) takes about 2 GiB before reload.sh checks its 40 GiB floor
# (CMUX_NEXT_MIN_FREE_GIB, tour-requirements.json), and only one build is on disk at a time (below). Before each
# arm, a home volume with less than 43 GiB free is logged as a warning and the arm runs anyway: a busy machine
# makes things slower, never makes them fail (run 1, job b872d155: 40 GiB at start, 38 GiB at the first build).
# Arm 2 also finds arm 1's app and the step's build caches still on disk. The mini scheduler admits this step at
# 48 GiB.
need_gib=43
check_free() {
  local free host
  host="$(hostname -s 2>/dev/null || echo unknown)"
  free="$(df -g "$HOME" 2>/dev/null | awk 'NR == 2 {print $4}')" || free=""
  if ! [[ "$free" =~ ^[0-9]+$ ]]; then
    echo "hung-renderer: warning: cannot read the free space of the home volume ($HOME) on $host before $1: '$free'; running anyway" >&2
    return 0
  fi
  echo "HUNG-RENDERER-DISK free before $1: $free GiB"
  if [ "$free" -lt "$need_gib" ]; then
    echo "hung-renderer: warning: $free GiB free on the home volume of $host before $1, under the $need_gib GiB floor (reload.sh's 40 GiB floor after the arm's ~2 GiB setup); running anyway" >&2
  fi
}
IFS=',' read -r -a arm_list <<< "$arms"
for arm in "${arm_list[@]}"; do
  label="${arm%%:*}" sha="${arm#*:}"
  if ! [[ "$label" =~ ^[a-z][a-z0-9]{0,11}$ && "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "hung-renderer: arm '$arm' is not LABEL:SHA (lowercase label, full 40-hex sha)" >&2
    exit 2
  fi
  check_free "arm $label"
  tree="$out/tree-$label"
  [ ! -e "$tree" ] || { echo "hung-renderer: arm label '$label' given twice" >&2; exit 2; }
  # A host-reference checkout has no origin remote (the worker fetches by URL), so fetch by URL, and only
  # when the commit is not here yet (swift-test-bench.sh's pattern).
  if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
    depth=()
    [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=(--depth=1)
    git fetch -q --no-tags ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$sha"
  fi
  git worktree add -q --detach "$tree" "$sha"
  trees+=("$tree")
  # A worktree checks out no submodules: the app build needs Ghostty's headers and the ghostty-next tree,
  # and GhosttyKit.xcframework (a prebuilt download), as tab-switch.sh.
  (
    cd "$tree"
    git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
    if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
      rm -rf GhosttyKit.xcframework
      if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
        export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
      fi
      ./scripts/download-prebuilt-ghosttykit.sh
    fi
    # CMUX_NEXT_REQUIRE_CEF=1: a missing CEF artifact fails the build here (embed-cef.sh otherwise builds an
    # app without Chromium and exits 0), not after both builds.
    CMUX_NEXT_REQUIRE_CEF=1 CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "hr$label" --config bench --no-global-cli-links 2>&1 | tee "$out/reload-$label.log"
  )
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload-$label.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "hung-renderer: the tagged reload of $label ($sha) printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/reload-$label.log" | head -n 60 >&2 || true
    exit 1
  fi
  # Only one build at a time fits: reload.sh needs 40 GiB free before each build, a cold build takes about 27 GiB,
  # and a perf mini has 40-60 GiB free. The app bundle is self-contained (embed-cef.sh copies Chromium in; cmux-tui
  # and acpmux are copied in), so it moves out to $out/apps and the arm's whole per-tag DerivedData and worktree go
  # before the next arm builds; the next arm then starts with about the space the step started with.
  derived="$(cd "$app/../../../.." && pwd)"
  if [[ "$(basename "$derived")" != cmux-* || "$app" != "$derived/Build/Products/"* ]]; then
    echo "hung-renderer: unexpected app path $app (not under a per-tag DerivedData)" >&2
    exit 1
  fi
  mkdir -p "$out/apps/$label"
  mv "$app" "$out/apps/$label/"
  app="$out/apps/$label/$(basename "$app")"
  rm -rf "$derived"
  git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"
  echo "HUNG-RENDERER-ARM $label $sha $app (free after build: $(df -g "$HOME" | awk 'NR == 2 {print $4}') GiB)"
  apps+=(--app "$label=$app")
done
mkdir -p artifacts
# A fleet step has no LaunchServices session: the bench launches the app binaries directly.
CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/hung-renderer-bench.py ${apps[@]+"${apps[@]}"} \
  --json artifacts/hung-renderer.json ${bench_args[@]+"${bench_args[@]}"}
