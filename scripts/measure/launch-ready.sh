#!/usr/bin/env bash
# What a person sees when cmux NEXT opens from the Dock (CMUX-629 "startup time less than 100ms", CMUX-631 "app
# bounces on the dock once when it opens"), timed from outside the app on a fleet Mac's console session:
#   cmux-ci run --class exclusive --measurement --label measure --display --key KEY \
#     --script scripts/measure/launch-ready.sh --ref <sha> [--arg=dmg=nightly|URL|build] [--arg=base=<sha>] \
#     [--arg=runs=5] --artifact .build/launch-ready/report.tgz --timeout 3600
#   dmg=nightly  the newest build the NIGHTLY feed offers (default); dmg=https://... one DMG
#   dmg=build    this checkout built as nightly-fresh-launch.sh builds it (a tagged Release app, ad-hoc signed)
#   base=SHA     with dmg=build: SHA built too, its runs interleaved with this checkout's (base 1, head 1, ...)
#   runs=N       measured relaunches per side (1 to 10, default 5), after one priming launch
# Each side gets one copy of the app and one home. The priming launch makes the home's state (a person's second
# launch on), then every measured launch is a relaunch through LaunchServices, activated, as a Dock click is.
# scripts/measure/launch-ready.swift times each one: finished_launching (the Dock's bounce ends), the first
# on-screen window, and the app's own marks. Prints LR-RUN per launch and LR-MEDIAN per side.
set -uo pipefail

main() {
  cd "$(dirname "$0")/../.." || exit 3
  local out="$PWD/.build/launch-ready" dmg=nightly base="" runs=5 arg rc=0 i side
  rm -rf "$out" && mkdir -p "$out" && chmod 0777 "$out"
  for arg in "$@"; do
    case "$arg" in
      dmg=nightly|dmg=build|dmg=https://*) dmg="${arg#dmg=}" ;;
      base=*) base="${arg#base=}" ;;
      runs=*) runs="${arg#runs=}" ;;
      *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  [[ "$runs" =~ ^([1-9]|10)$ ]] || { echo "runs= must be 1 to 10" >&2; exit 2; }
  [[ -z "$base" || ( "$dmg" == build && "$base" =~ ^[0-9a-f]{40}$ ) ]] || { echo "base= takes a 40-hex commit, with dmg=build" >&2; exit 2; }
  echo "LR host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
  xcrun swiftc -O -o "$out/launch-ready" scripts/measure/launch-ready.swift >"$out/swiftc.log" 2>&1 \
    || { echo "LR probe build failed"; cat "$out/swiftc.log"; exit 3; }
  local sides=(head)
  if [[ "$dmg" == build ]]; then
    # nightly-fresh-launch.sh's build_dmg, without running its main.
    source <(sed '/^main "\$@"; exit \$?$/d' scripts/measure/nightly-fresh-launch.sh)
    local head; head="$(git rev-parse HEAD)"
    if [[ -n "$base" ]]; then
      git cat-file -e "$base^{commit}" 2>/dev/null \
        || git fetch --quiet https://github.com/manaflow-ai/cmux.git "$base" || { echo "LR cannot fetch base $base"; exit 3; }
      git -c advice.detachedHead=false checkout --quiet --detach "$base" || exit 3
      build_dmg "$out" base release; rc=$?
      git -c advice.detachedHead=false checkout --quiet --detach "$head" || exit 3
      [[ $rc == 0 ]] || exit "$rc"
      sides=(base head)
    fi
    build_dmg "$out" head release || exit 3
  else
    if [[ "$dmg" == nightly ]]; then
      dmg="$(curl -fsSL --proto '=https' --retry 3 -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
        | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
    fi
    [[ "$dmg" == https://* ]] || { echo "LR no nightly DMG in the feed"; exit 3; }
    echo "LR dmg $dmg"
    curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-ready/1 -o "$out/head.dmg" "$dmg" || { echo "LR download failed"; exit 3; }
  fi
  source scripts/ci/lib/signing-runtime-guard.sh
  cmux_signing_runtime_guard || exit 3
  for side in "${sides[@]}"; do
    local mount="$out/mnt-$side"
    mkdir -p "$mount" "$out/$side"
    hdiutil attach "$out/$side.dmg" -nobrowse -readonly -mountpoint "$mount" >/dev/null || { echo "LR attach $side failed"; exit 3; }
    local found; found="$(find "$mount" -maxdepth 1 -name '*.app' | head -1)"
    ditto "$found" "$out/$side/$(basename "$found")" || exit 3
    hdiutil detach "$mount" >/dev/null || hdiutil detach -force "$mount" >/dev/null
    echo "LR app $side $(basename "$found") $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$out/$side/$(basename "$found")/Contents/Info.plist" 2>/dev/null)"
    probe "$out" "$side" prime 10 || rc=1
  done
  for ((i = 1; i <= runs; i++)); do
    for side in "${sides[@]}"; do
      probe "$out" "$side" "run$i" 6 || rc=1
    done
  done
  # Every process a launch left (the daemons a quit keeps): only ones started from this run's copies.
  local pids; pids="$(ps -axo pid=,command= | awk -v r="$out/" 'index($0, r) { print $1 }')"
  [[ -n "$pids" ]] && kill $pids 2>/dev/null
  python3 -I - "$out/runs.jsonl" <<'PY'
import json, statistics, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
for side in dict.fromkeys(r["side"] for r in rows):
    done = [r for r in rows if r["side"] == side and r["label"] != "prime" and r.get("window_on_screen") is not None]
    med = {"n": len(done)}
    for key in ("finished_launching", "window_on_screen", "active", "request_to_start"):
        vals = [r[key] for r in done if r.get(key) is not None]
        med[key] = round(statistics.median(vals), 1) if vals else None
    for key in ("main_start", "main.nsapp", "app.did_finish_launching_entry", "launch_snapshot_shown", "did_finish_launching_end",
                "first_window_frame_committed", "home.first_page"):
        vals = [r["marks"][key] for r in done if key in r["marks"]]
        med[key] = round(statistics.median(vals), 1) if vals else None
    print("LR-MEDIAN", side, json.dumps(med), flush=True)
PY
  tar -czf "$out.tgz" -C "$out" --exclude '*.dmg' --exclude '*.app' . 2>/dev/null && mv "$out.tgz" "$out/report.tgz"
  exit "$rc"
}

# probe OUT SIDE LABEL SETTLE_S: one launch of SIDE's copy with SIDE's home, in the console session.
probe() {
  local out="$1" side="$2" label="$3" settle="$4" app line
  app="$(find "$out/$side" -maxdepth 1 -name '*.app' | head -1)"
  mkdir -p "$out/home-$side" && chmod 0777 "$out/home-$side"
  line="$(GITHUB_WORKSPACE="$PWD" scripts/ci/frame-pacing/console-session.sh "$out/launch-ready" "$app" "$out/home-$side" "$label" "$settle" 2>>"$out/probe.log" | grep '^LR-RUN ')"
  [[ -n "$line" ]] || { echo "LR-RUN $side $label no result"; return 1; }
  echo "$line" | sed "s/^LR-RUN /LR-RUN $side /"
  echo "${line#LR-RUN }" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); r["side"]=sys.argv[1]; print(json.dumps(r))' "$side" >>"$out/runs.jsonl"
  [[ "$line" != *'"error"'* ]]
}

main "$@"; exit $?
