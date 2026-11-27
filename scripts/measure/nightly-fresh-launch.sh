#!/usr/bin/env bash
# Where a published cmux NEXT nightly's fresh-home launch spends its time (goal next-launch-instant, CMUX-571),
# on a fleet Mac with a console session: per round, a fresh copy with a fresh home (the nightly dogfood's
# launch), the same copy with another fresh home, and that home warm (scripts/measure/nightly-fresh-launch.py).
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/nightly-fresh-launch.sh --ref <sha> [--arg=dmg=nightly|URL|build] [--arg=rounds=2] \
#     [--arg=base=<sha>] --artifact .build/nightly-fresh-launch/report.tgz --timeout 1800
#   dmg=nightly  the newest build the NIGHTLY feed offers (default); dmg=https://... one DMG
#   dmg=build    an app built from this checkout (scripts/reload.sh --release, a tagged build: ad-hoc signed, not
#                the nightly's Developer ID), put in a DMG, so an app change is measured by this same harness
#   base=SHA     with dmg=build: also build SHA (a commit of this repository) in the same DerivedData, and run its
#                rounds interleaved with this checkout's on this one Mac (base round 1, head round 1, ...).
#                Prints NFL-AB <base|head> <arm> lines with the medians of each
#   config=bench with dmg=build: --config bench (the debug.* commands) instead of --release
#   rounds=N     rounds of the three launches (1 to 5, default 2)
#   arms=extra   also the pre-warm arms and the unified log around each fresh launch (nightly-fresh-launch.py --arms)
#   arms=prewarm also only the pre-warm arms (PREWARM_ARMS)
#   arms=adhoc   also a new copy re-signed ad hoc (ADHOC_ARMS): does a dmg=build app's first launch cost what the DMG's does
#   arms=update  only the update path's launch (UPDATE_ARMS: prewarm-update-moved, what the nightly dogfood reads as
#                app_update_launch_ms), none of the base arms
#   arms=premain also the PREMAIN_ARMS (a new copy warmed one way each) and a log stream of every launch: what a
#                new copy's pre-main is made of (NFL-PREMAIN, NFL-PREMAIN-LOG and NFL-VERIFY lines)
# Prints NFL-FACT, NFL-LAUNCH, NFL-MARKS and NFL-MEDIAN lines; keeps report.json in report.tgz.
set -uo pipefail

# One function, called on the last line: bash has read all of it before a base=SHA checkout changes this file.
main() {
  cd "$(dirname "$0")/../.." || exit 3
  local out="$PWD/.build/nightly-fresh-launch"
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  local dmg=nightly rounds=2 arms=base base="" config=release arg
  for arg in "$@"; do
    case "$arg" in
      dmg=nightly|dmg=build|dmg=https://*) dmg="${arg#dmg=}" ;;
      rounds=*) rounds="${arg#rounds=}" ;;
      arms=base|arms=extra|arms=prewarm|arms=adhoc|arms=premain|arms=update) arms="${arg#arms=}" ;;
      base=*) base="${arg#base=}" ;;
      config=bench|config=release) config="${arg#config=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$rounds" =~ ^[1-5]$ ]] || { echo "rounds= must be 1 to 5" >&2; exit 2; }
  [[ -z "$base" || ( "$dmg" == build && "$base" =~ ^[0-9a-f]{40}$ ) ]] || { echo "base= takes a 40-hex commit, with dmg=build" >&2; exit 2; }
  echo "NFL host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  if [[ "$dmg" == build ]]; then
    # build_dmg resolves each side's acpmux with this copy: a base commit may predate resolve-acpmux.sh. Each side's
    # Screen Sharing helper phase runs this copy too (NFL_SCREEN_HELPER_PHASE).
    cp scripts/cmux-next/resolve-acpmux.sh "$out/resolve-acpmux.sh" && export NFL_RESOLVE_ACPMUX="$out/resolve-acpmux.sh"
    cp scripts/cmux-next/bundle-screen-sharing-helper.sh "$out/bundle-screen-sharing-helper.sh" \
      && export NFL_SCREEN_HELPER_PHASE="$out/bundle-screen-sharing-helper.sh"
    build_ab "$out" "$rounds" "$arms" "$base" "$config"
    return $?
  fi
  if [[ "$dmg" == nightly ]]; then
    dmg="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
      | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
  fi
  [[ "$dmg" == https://* ]] || { echo "NFL no nightly DMG in the feed"; exit 3; }
  echo "NFL dmg $dmg"
  curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-nightly-fresh-launch/1 -o "$out/in.dmg" "$dmg" || { echo "NFL download failed"; exit 3; }
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$PWD/scripts/measure/nightly-fresh-launch.py" \
    --dmg "$out/in.dmg" --out "$out/run" --rounds "$rounds" --arms "$arms" 2>&1 | tee "$out/run.log"
  local rc=${PIPESTATUS[0]}
  rm -f "$out/in.dmg"
  tar -czf "$out.tgz" -C "$out" . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

# Builds the checkout at its current commit into OUT/NAME.dmg (a tagged Release app; a fleet measurement step's
# DerivedData is shared by the checkout's builds, so the second build recompiles only what the two commits change).
# Each NAME has its own tag, nflab-NAME: the tag names the app's daemon session (cmux-app-<tag>), whose socket is one
# per user (the account's temporary folder, whatever HOME a launch has). With one tag for base and head, the owner a
# base launch kept for its terminals held that socket, and the head's `server ensure` refused it as another state
# dir's, so no head launch ever connected (cmux#47182's A/B, 2026-11-20: head never seeded, front null, 0/19 attached).
build_dmg() {
  local out="$1" name="$2" config="$3" app configuration=(--release)
  [[ "$config" == bench ]] && configuration=(--config bench)
  [[ "$config" == debug ]] && configuration=(--config debug) # launch-ready.sh layout=movequit: DEBUG's debug.* commands
  for sub in ghostty ghostty-next; do
    git submodule update --init --depth 1 "$sub" >>"$out/build-$name.log" 2>&1 || { echo "NFL submodule $sub failed" >&2; return 3; }
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh >>"$out/build-$name.log" 2>&1 || { echo "NFL GhosttyKit download failed" >&2; return 3; }
  fi
  # acpmux before reload.sh, for this commit's tree: a fleet measurement Mac never runs Cargo, and an older commit's
  # reload.sh stops on a cache miss ("no cached acpmux for this checkout"). The copy taken before any checkout
  # (NFL_RESOLVE_ACPMUX) also resolves a base commit that predates resolve-acpmux.sh; reload.sh takes the path as given.
  # One Mac's launch: the app and its acpmux for this Mac's architecture, as a fleet measurement step's reload.sh
  # already builds it, also when this runs outside one (the published acpmux is arm64 only).
  export CMUX_RELOAD_NATIVE_ARCH="${CMUX_RELOAD_NATIVE_ARCH:-1}"
  local resolve="${NFL_RESOLVE_ACPMUX:-$PWD/scripts/cmux-next/resolve-acpmux.sh}" acpmux=() arch=()
  [[ "$CMUX_RELOAD_NATIVE_ARCH" == 1 && -z "${CMUX_NEXT_ACPMUX_ARCHS:-}" ]] \
    && arch=(CMUX_NEXT_ACPMUX_ARCHS="$([[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]] && echo arm64 || uname -m)")
  if [[ -z "${CMUX_NEXT_ACPMUX_BIN:-}" && -x "$resolve" ]]; then
    local bin
    bin="$(env ${arch[@]+"${arch[@]}"} "$resolve" --repo "$PWD" 2>>"$out/build-$name.log")" \
      || { echo "NFL acpmux for $name: none (build-$name.log)" >&2; return 3; }
    acpmux=(CMUX_NEXT_ACPMUX_BIN="$bin")
    echo "NFL acpmux $name $bin"
  fi
  # The Screen Sharing helper phase from the copy taken before any checkout (NFL_SCREEN_HELPER_PHASE), on a commit
  # that has the phase: one from before #45226 named the helper "File Doesn't Exist, Will Create: ..." when this
  # DerivedData's second build found no Info.plist, and the head build failed (launch-ready A/Bs, 2026-11-17). The
  # commit's own copy is back before the next checkout.
  local phase=scripts/cmux-next/bundle-screen-sharing-helper.sh overlaid=0
  if [[ -n "${NFL_SCREEN_HELPER_PHASE:-}" && -f "$NFL_SCREEN_HELPER_PHASE" && -f "$phase" ]] \
    && ! cmp -s "$NFL_SCREEN_HELPER_PHASE" "$phase"; then
    cp "$NFL_SCREEN_HELPER_PHASE" "$phase" && overlaid=1 && echo "NFL $name builds with this checkout's $phase"
  fi
  local started=$SECONDS
  env ${acpmux[@]+"${acpmux[@]}"} CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "nflab-$name" --no-global-cli-links "${configuration[@]}" >>"$out/build-$name.log" 2>&1
  [[ "$overlaid" == 0 ]] || git checkout --quiet -- "$phase"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/build-$name.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "NFL build $name failed: no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/build-$name.log" | head -n 60 >&2
    tail -n 40 "$out/build-$name.log" >&2
    return 3
  fi
  hdiutil create -quiet -ov -fs HFS+ -format UDRO -volname "nfl-$name" -srcfolder "$app" "$out/$name.dmg" || { echo "NFL hdiutil create $name failed" >&2; return 3; }
  echo "NFL build $name $(git rev-parse HEAD) $((SECONDS - started)) s $(du -sh "$app" | cut -f1)"
}

build_ab() {
  local out="$1" rounds="$2" arms="$3" base="$4" config="$5" head rc=0 i side
  head="$(git rev-parse HEAD)"
  # The launches below run after the checkout is back at HEAD: base's tree only builds.
  if [[ -n "$base" ]]; then
    local depth=()
    [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == true ]] && depth=(--depth=1) # a full clone stays full
    # A fleet step's warm checkout comes from the fleet mirror and has no `origin` remote: fetch from the repository's URL.
    git cat-file -e "$base^{commit}" 2>/dev/null \
      || git fetch --quiet ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$base" \
      || { echo "NFL cannot fetch base $base" >&2; exit 3; }
    git -c advice.detachedHead=false checkout --quiet --detach "$base" || exit 3
    build_dmg "$out" base "$config"; rc=$?
    git -c advice.detachedHead=false checkout --quiet --detach "$head" || exit 3
    [[ $rc == 0 ]] || exit "$rc"
  fi
  build_dmg "$out" head "$config" || exit 3
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  local sides=(head)
  [[ -n "$base" ]] && sides=(base head)
  for ((i = 1; i <= rounds; i++)); do
    for side in "${sides[@]}"; do
      echo "NFL-AB-ROUND $i $side"
      GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh python3 -I "$PWD/scripts/measure/nightly-fresh-launch.py" \
        --dmg "$out/$side.dmg" --out "$out/run-$side-$i" --rounds 1 --arms "$arms" 2>&1 | tee -a "$out/run.log" | sed "s/^/[$side] /"
      [[ ${PIPESTATUS[0]} == 0 ]] || rc=1
    done
  done
  python3 -I - "$out" "${sides[@]}" <<'PY'
import json, statistics, sys
from pathlib import Path
out, sides = Path(sys.argv[1]), sys.argv[2:]
for side in sides:
    rows = []
    for report in sorted(out.glob(f"run-{side}-*/report.json")):
        rows += json.loads(report.read_text())["launches"]
    for arm in dict.fromkeys(r["arm"] for r in rows):
        done = [r for r in rows if r["arm"] == arm and r["rendered_at"] is not None]
        med = {"n": len(done)}
        for key in ("pre_main", "to_frame", "to_page", "frame", "page", "harness"):
            vals = [r["phases"][key] for r in done if r["phases"].get(key) is not None]
            med[key] = round(statistics.median(vals), 1) if vals else None
        print("NFL-AB", side, arm, json.dumps(med), flush=True)
PY
  rm -f "$out"/*.dmg
  tar -czf "$out.tgz" -C "$out" . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

main "$@"; exit $?
