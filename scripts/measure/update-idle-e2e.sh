#!/usr/bin/env bash
# Update when idle, end to end on one fleet Mac (Leo, 2026-11-19: "when it's idle, it's able to ... update
# automatically ... maybe even having it as an opt-in option would be pretty interesting. Yeah, like update when idle").
# Each side builds a bench app (--config bench: the NIGHTLY's Release optimization with the debug control surface);
# scripts/cmux-next/update-harness/idle_e2e.py runs a copy of it as v1 with updates.installWhenIdle on (setting=on, the
# opt-in) or unset (setting=unset, for a build where installing when idle is the default)
# (installWhenIdleMinutes 1) and serves a newer copy on a loopback appcast. The head must install by itself only after
# the running agent turn ended, the unsent draft was cleared and the idle time passed, with every agent host kept
# (counts and pids before and after); the base, without the setting, is the control: nothing installs.
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/update-idle-e2e.sh --ref <a commit with this file> \
#     --arg=base=<sha> --arg=head=<sha> [--arg=rounds=1] [--arg=idle_minutes=1] [--arg=control=1] \
#     [--arg=setting=on|unset] [--arg=tag=uide] \
#     --artifact .build/update-idle-e2e/report.tgz --timeout 7200
#   base=SHA, head=SHA  40-hex commits (head: the build with Update When Idle; base: the control)
#   rounds=N            1 to 3 head runs (default 1); control=0 skips the base run
#   idle_minutes=N      updates.installWhenIdleMinutes, 1 to 5 (default 1)
#   setting=on|unset    updates.installWhenIdle in v1's config (default on)
#   tag=NAME            the bench app's build tag (default uide); a run refuses a tag whose agent home exists
# Prints UIE <side> <round> {...} per run; each run's result.json is in the report.
set -uo pipefail

main() {
  cd "$(dirname "$0")/../.." || exit 3
  local out tools report="$PWD/.build/update-idle-e2e/report.tgz"
  mkdir -p "$PWD/.build" || exit 3
  out="$(mktemp -d "$PWD/.build/update-idle-e2e.XXXXXX")" || exit 3
  trap "rm -rf -- $(printf %q "$out")" EXIT  # the report is copied out first; a failed or killed run leaks nothing
  chmod 0777 "$out"
  local work_dirs=()
  # The harness as of this commit, whatever the sides' trees hold.
  tools="$out/tools" && mkdir -p "$tools" && cp -R scripts/cmux-next/update-harness "$tools/" \
    && cp scripts/cmux-next/tag_teardown.py "$tools/"  # run.py and idle_e2e.py import it from their parent folder
  local base="" head rounds=1 idle=1 control=1 setting=on tag=uide arg rc=0 i side
  head="$(git rev-parse HEAD)"
  local checkout="$head"
  for arg in "$@"; do
    case "$arg" in
      base=*) base="${arg#base=}" ;;
      head=*) head="${arg#head=}" ;;
      rounds=*) rounds="${arg#rounds=}" ;;
      idle_minutes=*) idle="${arg#idle_minutes=}" ;;
      control=*) control="${arg#control=}" ;;
      setting=*) setting="${arg#setting=}" ;;
      tag=*) tag="${arg#tag=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$rounds" =~ ^[1-3]$ ]] || { echo "rounds= must be 1 to 3" >&2; exit 2; }
  [[ "$idle" =~ ^[1-5]$ ]] || { echo "idle_minutes= must be 1 to 5" >&2; exit 2; }
  [[ "$control" =~ ^[01]$ ]] || { echo "control= is 0 or 1" >&2; exit 2; }
  [[ "$setting" == on || "$setting" == unset ]] || { echo "setting= is on or unset" >&2; exit 2; }
  [[ "$tag" =~ ^[a-z0-9]{1,24}$ ]] || { echo "tag= takes 1 to 24 lowercase letters or digits" >&2; exit 2; }
  [[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "base= and head= take 40-hex commits" >&2; exit 2; }
  echo "UIE host chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  local sides=(head)
  [[ "$control" == 1 ]] && sides=(base head)
  for side in "${sides[@]}"; do
    local sha="$base"
    [[ "$side" == head ]] && sha="$head"
    fetch_checkout "$sha" || exit 3
    build_app "$out" "$side" || { git -c advice.detachedHead=false checkout --quiet --detach "$checkout"; exit 3; }
  done
  # The fake agent the harness drives comes from this checkout (fake_agent.py beside acpmux's tests).
  git -c advice.detachedHead=false checkout --quiet --detach "$head" || exit 3
  run_side() {
    local side="$1" round="$2" expect=install
    work_dirs+=("$out/run-$side-$round/work")
    [[ "$side" == base ]] && expect=none
    echo "UIE-ROUND $round $side expect=$expect"
    GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$tools/update-harness/idle_e2e.py" \
      --app "$out/$side/cmux DEV $tag.app" --tag "$tag" --out "$out/run-$side-$round" --expect "$expect" \
      --idle-minutes "$idle" --install-when-idle "$setting" --fake-agent "$PWD/cmux-tui/crates/acpmux/tests/fake_agent.py" \
      2>&1 | tee -a "$out/run.log" | sed "s/^/[$side] /"
    local status=${PIPESTATUS[0]}
    python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print("UIE", sys.argv[2], sys.argv[3], json.dumps({k: r.get(k) for k in ("expect","passed","failure","counts","verdicts","version_before","version_after","install_after_last_input_s")}))' \
      "$out/run-$side-$round/result.json" "$side" "$round" 2>/dev/null || echo "UIE $side $round no result.json"
    return "$status"
  }
  [[ "$control" == 1 ]] && { run_side base 1 || rc=1; }
  for ((i = 1; i <= rounds; i++)); do
    run_side head "$i" || rc=1
  done
  git -c advice.detachedHead=false checkout --quiet --detach "$checkout"
  rm -rf "$out/base" "$out/head" ${work_dirs[@]+"${work_dirs[@]}"}
  mkdir -p "$(dirname "$report")" || exit 3
  tar -czf "$out.tgz" -C "$out" . 2>/dev/null && mv "$out.tgz" "$report" || exit 3
  exit "$rc"
}

fetch_checkout() {
  local sha="$1" depth=()
  [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && depth=(--depth=1)
  # A fleet step's origin is the fleet mirror, which holds feat-cmux-next only: a PR or lane commit comes from GitHub.
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch --quiet ${depth[@]+"${depth[@]}"} origin "$sha" 2>/dev/null \
    || git fetch --quiet ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$sha" || { echo "UIE cannot fetch $sha" >&2; return 3; }
  git -c advice.detachedHead=false checkout --quiet --detach "$sha"
}

# Builds the checkout's bench app with tag TAG and copies it to OUT/SIDE/.
build_app() {
  local out="$1" side="$2" app started=$SECONDS
  for sub in ghostty ghostty-next; do
    git submodule update --init --depth 1 "$sub" >>"$out/build-$side.log" 2>&1 || { echo "UIE submodule $sub failed" >&2; return 3; }
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh >>"$out/build-$side.log" 2>&1 || { echo "UIE GhosttyKit download failed" >&2; return 3; }
  fi
  # Build the changed rule into the test bundle; the checked-in binary pin may predate it.
  CMUX_APP_FFI_OUT="$out/ffi-$side" ./scripts/cmux-next/build-app-ffi.sh >>"$out/build-$side.log" 2>&1 \
    || { echo "UIE FFI build $side failed" >&2; return 3; }
  CMUX_FLEET_BUILD_TAG="$tag" ./scripts/cmux-next/build-acpmux.sh >>"$out/build-$side.log" 2>&1 || { echo "UIE acpmux build $side failed" >&2; tail -n 40 "$out/build-$side.log" >&2; return 3; }
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links --config bench >>"$out/build-$side.log" 2>&1 \
    || { echo "UIE app build $side failed" >&2; tail -n 40 "$out/build-$side.log" >&2; return 3; }
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/build-$side.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "UIE build $side failed: no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/build-$side.log" | head -n 60 >&2
    tail -n 40 "$out/build-$side.log" >&2
    return 3
  fi
  mkdir -p "$out/$side" && ditto "$app" "$out/$side/cmux DEV $tag.app" || { echo "UIE copy $side failed" >&2; return 3; }
  cp "$out/ffi-$side/macos/libcmux_app_ffi.dylib" "$out/$side/cmux DEV $tag.app/Contents/Frameworks/libcmux_app_ffi.dylib" || return 3
  codesign --force --deep --sign - "$out/$side/cmux DEV $tag.app" >>"$out/build-$side.log" 2>&1 || return 3
  echo "UIE build $side $(git rev-parse HEAD) $((SECONDS - started)) s $(du -sh "$app" | cut -f1)"
}

main "$@"
