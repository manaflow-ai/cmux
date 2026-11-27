#!/usr/bin/env bash
# A real Sparkle update of cmux NEXT from one commit's build to another's, with terminals that have no tab: does an
# update lose them? Each one is kept only by an attach stream (as the app keeps an agent's terminal), stays without a
# tab for longer than the reap grace, and gets its stream again a few seconds after the new build's daemon took over
# (returning=); the rest get none and must end. More than 16 at once is the case a nightly lost: the new daemon ended
# all of them 3.5 s after it took over. Both builds are bench apps with one tag, built on one Mac; the update harness
# (scripts/cmux-next/update-harness/run.py --v2-app --unplaced-count) runs old as v1 and updates it to new.
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/update-migration.sh --ref <a feat-cmux-next commit with this file> \
#     --arg=old=<sha> --arg=new=<sha> [--arg=unplaced=20] [--arg=returning=18] [--arg=control=1] \
#     --artifact .build/update-migration/report.tgz --timeout 7200
#   old=SHA, new=SHA  40-hex commits; new defaults to the checkout
#   unplaced=N        terminals with no tab, 1 to 32 (default 20); returning=N  how many get their stream again (default all but 2)
#   return_delay=S    seconds from the new daemon to the returning streams (default 8); settle=S  to the check (default 90)
#   control=1         first update old to a restamped copy of old (the old daemon code takes over): what old loses
# Prints per update UMIG <round> {"returning":N,"returning_kept":N,"abandoned":N,"abandoned_ended":N,
# "returning_ended_after_s":[...],...} (seconds after the new daemon that a returning terminal's process was first seen
# gone) and UMIG-RESULT <round> pass|fail. The exit status is the old-to-new update's; the control only reports.
set -uo pipefail

# One function, called on the last line: bash has read all of it before a checkout changes this file.
main() {
  cd "$(dirname "$0")/../.." || exit 3
  source scripts/measure/build-progress.sh
  local out="$PWD/.build/update-migration" tools
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  # The harness as of this commit, whatever the sides' trees hold.
  tools="$out/tools" && mkdir -p "$tools" && cp -R scripts/cmux-next/update-harness "$tools/" \
    && cp scripts/cmux-next/tag_teardown.py scripts/cmux-next/state_wait.py "$tools/"  # run.py imports them from its parent folder
  local old="" new unplaced=20 returning="" delay=8 settle=90 control=0 arg rc=0 side round
  new="$(git rev-parse HEAD)"
  local checkout="$new"
  for arg in "$@"; do
    case "$arg" in
      old=*) old="${arg#old=}" ;;
      new=*) new="${arg#new=}" ;;
      unplaced=*) unplaced="${arg#unplaced=}" ;;
      returning=*) returning="${arg#returning=}" ;;
      return_delay=*) delay="${arg#return_delay=}" ;;
      settle=*) settle="${arg#settle=}" ;;
      control=*) control="${arg#control=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$unplaced" =~ ^[0-9]{1,2}$ && "$unplaced" -ge 1 && "$unplaced" -le 32 ]] || { echo "unplaced= takes 1 to 32" >&2; exit 2; }
  [[ -n "$returning" ]] || returning=$((unplaced > 2 ? unplaced - 2 : unplaced))
  [[ "$returning" =~ ^[0-9]{1,2}$ && "$returning" -le "$unplaced" ]] || { echo "returning= takes 0 to unplaced=" >&2; exit 2; }
  [[ "$delay" =~ ^[0-9]+(\.[0-9]+)?$ && "$settle" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "return_delay= and settle= take seconds" >&2; exit 2; }
  [[ "$control" =~ ^[01]$ ]] || { echo "control= takes 0 or 1" >&2; exit 2; }
  [[ "$old" =~ ^[0-9a-f]{40}$ && "$new" =~ ^[0-9a-f]{40}$ && "$old" != "$new" ]] || { echo "old= and new= take two 40-hex commits" >&2; exit 2; }
  echo "UMIG host chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  for side in old new; do
    local sha="$old"
    [[ "$side" == new ]] && sha="$new"
    fetch_checkout "$sha" || exit 3
    build_app "$out" "$side" || { git -c advice.detachedHead=false checkout --quiet --detach "$checkout"; exit 3; }
  done
  git -c advice.detachedHead=false checkout --quiet --detach "$checkout" || exit 3
  local rounds=(old-to-new)
  [[ "$control" == 1 ]] && rounds=(control-old-to-old old-to-new)
  for round in "${rounds[@]}"; do
    local target=(--v2-app "$out/new/cmux DEV umig.app")
    [[ "$round" == control-old-to-old ]] && target=(--handoff)
    echo "UMIG-ROUND $round unplaced=$unplaced returning=$returning"
    GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$tools/update-harness/run.py" \
      --app "$out/old/cmux DEV umig.app" "${target[@]}" --tag umig --out "$out/run-$round" --sessions \
      --unplaced-count "$unplaced" --unplaced-return "$returning" --unplaced-return-delay "$delay" --unplaced-settle "$settle" \
      2>&1 | tee -a "$out/run.log" | sed "s/^/[$round] /"
    local status=${PIPESTATUS[0]}
    grep -a '^UNPLACED ' "$out/run.log" | tail -n 1 | sed "s/^UNPLACED /UMIG $round /"
    if [[ "$status" == 0 ]]; then
      echo "UMIG-RESULT $round pass"
    else
      echo "UMIG-RESULT $round fail (harness exit $status)"
      [[ "$round" == old-to-new ]] && rc=1
    fi
  done
  rm -rf "$out/old" "$out/new"
  tar -czf "$out.tgz" -C "$out" . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

fetch_checkout() {
  local sha="$1" depth=()
  [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && depth=(--depth=1) # a full clone stays full
  # A fleet step's origin is the fleet mirror, which holds feat-cmux-next only: a PR or lane commit comes from GitHub.
  git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch --no-recurse-submodules --quiet ${depth[@]+"${depth[@]}"} origin "$sha" 2>/dev/null \
    || git fetch --no-recurse-submodules --quiet ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$sha" || { echo "UMIG cannot fetch $sha" >&2; return 3; }
  git -c advice.detachedHead=false checkout --quiet --detach "$sha"
}

# Builds the checkout's bench app with tag umig (both sides one bundle id; the second build recompiles only what the
# two commits change) and copies it to OUT/SIDE/.
build_app() {
  local out="$1" side="$2" app started=$SECONDS
  for sub in ghostty ghostty-next; do
    git submodule update --init --depth 1 "$sub" >>"$out/build-$side.log" 2>&1 || { echo "UMIG submodule $sub failed" >&2; return 3; }
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh >>"$out/build-$side.log" 2>&1 || { echo "UMIG GhosttyKit download failed" >&2; return 3; }
  fi
  measure_quiet "UMIG acpmux build $side" "$out/build-$side.log" env CMUX_FLEET_BUILD_TAG=umig ./scripts/cmux-next/build-acpmux.sh || { echo "UMIG acpmux build $side failed" >&2; tail -n 40 "$out/build-$side.log" >&2; return 3; }
  measure_quiet "UMIG build $side" "$out/build-$side.log" env CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag umig --no-global-cli-links --config bench
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/build-$side.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "UMIG build $side failed: no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/build-$side.log" | head -n 60 >&2
    tail -n 40 "$out/build-$side.log" >&2
    return 3
  fi
  mkdir -p "$out/$side" && ditto "$app" "$out/$side/cmux DEV umig.app" || { echo "UMIG copy $side failed" >&2; return 3; }
  echo "UMIG build $side $(git rev-parse HEAD) $((SECONDS - started)) s $(du -sh "$app" | cut -f1)"
}

main "$@"
