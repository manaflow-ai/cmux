#!/usr/bin/env bash
# The iPhone app's surfaces under bad links: time to first content, time to interactive, the
# visible gap after a drop, and bytes and round trips to first content, per link profile, surface,
# cold/warm/reconnect and history scale (1x, 10x, 100x), p50 and p95 over n runs. Every mobile
# speed fix shows its before and after from this one command:
#
#   cmux-ci run --class exclusive --label measure --script scripts/measure/ios-network-conditions.sh \
#     --ref SHA [--arg before=SHA] [--arg n=5] [--arg profiles=lte,elevator-30s] \
#     [--arg surfaces=terminal,chat] [--arg scales=1x,10x,100x] [--arg seed=0] \
#     --artifact .build/ios-network-conditions/report.json --timeout 7200
#
# Headless leg (Linux or Mac, no simulator): real daemons behind cmux-fault's seeded link shaper
# (cmux-tui/crates/cmux-fault/src/shaper.rs), with the link rows in
# cmux-tui/crates/cmux-fault/link-profiles.json (named, versioned, each citing its source):
#   terminal: cmux-tui/crates/cmux-tui/tests/mobile_link_conditions.rs (the real cmux-tui daemon,
#     the phone's `daemon` service requests: set-client-info, identify, attach-surface, send);
#   chat: cmux-tui/crates/acpmux/tests/mobile_link_conditions.rs (the real acpmux, the phone's
#     `acpmux` service requests: _acpmux/watch, _acpmux/attach, afterSeq on reconnect).
# Each prints NETCOND lines; ios-network-conditions-report.py makes report.json (profile x surface
# x phase x scale x metric: p50, p95, n) and report.md (the table a PR body pastes, with a before
# column and the change when before= is given).
#
# before=SHA builds the same benches at that ref. A ref older than the harness gets the harness
# files laid over it (the shaper, the profiles, the two bench files and their dev-dependency), so
# the code under test is the ref's and the yardstick is this one. Same worker, same seeds.
# Local, without cmux-ci: scripts/measure/ios-network-conditions.sh [args] (needs cargo).
#
# Simulator leg, leg=sim (R1, time to readable): the iPhone app itself with no Mac reachable, from
# its own marks (LaunchMarks `<surface>_first_content_cached|live`), per tap: cold_launch,
# warm_foreground, open_chat, open_terminal, switch_session (cmux-next-ios/UITests/
# ReadFirstUITests.swift), cold (a fresh simulator boot per run) and warm. Rows: surface
# `sim:<tap>`, profile offline-sim@1, metric r1_ms (tap to the first content frame, cached or
# not) and r2_ms (tap to the first frame from a reply; in mock mode the in-process mock), into the
# same report.json and report.md.
#   On a Mac with Xcode (a simulator worker): runs scripts/ci/cmux-next-ios-sim.sh test
#     ui=ReadFirstUITests,ReadFirstColdUITests coldruns=N as a sibling step, then reads its evidence.
#   Anywhere else: evidence=PATH reads a finished fleet simulator step's evidence.zip (or folder).
#   The fleet controller runs only scripts/ci/cmux-next-ios-sim.sh on --class simulator and refuses
#   arguments outside its pattern ("test takes only=..., ui=..., video, profile, duress=SPEC,
#   device=NAME and reducemotion=1, got \"coldruns=20\"") and every env but CMUX_CI_XCODE_APP, so the
#   cold run count comes from ReadFirstColdUITests' `static let coldRuns = 20`, and the
#   route from a lane VM is three commands:
#     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg test \
#       --arg ui=ReadFirstUITests,ReadFirstColdUITests --artifact artifacts/ios-sim/evidence.zip
#     cmux-ci artifact STEP_ID /tmp/rf/evidence.zip
#     scripts/measure/ios-network-conditions.sh leg=sim evidence=/tmp/rf/evidence.zip
set -euo pipefail
trap 'echo "ios-network-conditions.sh: line $LINENO exited $? ($BASH_COMMAND)" >&2' ERR

before="" n=5 profiles="" surfaces="terminal,chat" scales="1x,10x,100x" seed=0 leg=headless evidence=""
for kv in "$@"; do
  case "$kv" in
    before=*) before="${kv#*=}" ;;
    n=*) n="${kv#*=}" ;;
    profiles=*) profiles="${kv#*=}" ;;
    surfaces=*) surfaces="${kv#*=}" ;;
    scales=*) scales="${kv#*=}" ;;
    seed=*) seed="${kv#*=}" ;;
    leg=*) leg="${kv#*=}" ;;
    evidence=*) evidence="${kv#*=}" ;;
    *) echo "ios-network-conditions.sh: unknown arg '$kv' (before=, n=, profiles=, surfaces=, scales=, seed=, leg=, evidence=)" >&2; exit 2 ;;
  esac
done
[[ -z "$before" || "$before" =~ ^[0-9a-f]{40}$ ]] || { echo "ios-network-conditions.sh: before= is a 40-character SHA" >&2; exit 2; }
[[ "$n" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "ios-network-conditions.sh: n is 1-999" >&2; exit 2; }
[[ "$seed" =~ ^[0-9]{1,9}$ ]] || { echo "ios-network-conditions.sh: seed is a number" >&2; exit 2; }
[[ "$surfaces" =~ ^(terminal|chat)(,(terminal|chat))?$ ]] || { echo "ios-network-conditions.sh: surfaces=terminal,chat" >&2; exit 2; }
[[ "$scales" =~ ^[0-9]+x(,[0-9]+x)*$ ]] || { echo "ios-network-conditions.sh: scales=1x,10x,100x" >&2; exit 2; }
[[ -z "$profiles" || "$profiles" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { echo "ios-network-conditions.sh: profiles=NAME,..." >&2; exit 2; }
[[ "$leg" == headless || "$leg" == sim ]] || { echo "ios-network-conditions.sh: leg=headless or leg=sim" >&2; exit 2; }

if [[ "$leg" == sim ]]; then
  root="$(git rev-parse --show-toplevel)"
  work="$root/.build/ios-network-conditions"
  mkdir -p "$work"
  if [[ -z "$evidence" ]]; then
    command -v xcrun >/dev/null || {
      echo "ios-network-conditions.sh: leg=sim needs a Mac with Xcode (a simulator worker) or evidence=PATH;" \
        "from Linux run the fleet step in this script's header, then pass its evidence.zip" >&2; exit 2; }
    (( n >= 1 && n <= 30 )) || { echo "ios-network-conditions.sh: leg=sim takes n=1-30 cold runs" >&2; exit 2; }
    code=0
    "$root/scripts/ci/cmux-next-ios-sim.sh" test ui=ReadFirstUITests,ReadFirstColdUITests "coldruns=$n" || code=$?
    echo "NETCOND-STATUS sim read-first exit=$code"
    evidence="$root/artifacts/ios-sim"
  fi
  python3 -I "$root/scripts/measure/ios-read-first-rows.py" "$evidence" >"$work/lines-sim.txt"
  echo "NETCOND-MACHINE leg=sim evidence=$evidence rows=$(wc -l <"$work/lines-sim.txt" | tr -d ' ')"
  sed 's/^after /NETCOND /' "$work/lines-sim.txt"
  # One report: the sim rows join the headless leg's lines when that ran into the same folder.
  cat "$work/lines-sim.txt" >>"$work/lines.txt"
  python3 "$root/scripts/measure/ios-network-conditions-report.py" "$work/lines.txt" \
    --json "$work/report.json" --markdown "$work/report.md" --after "$(git rev-parse HEAD)"
  sed 's/^/NETCOND-TABLE /' "$work/report.md"
  exit "${code:-0}"
fi
command -v cargo >/dev/null || { echo "ios-network-conditions.sh: needs cargo on PATH; run it through cmux-ci run" >&2; exit 2; }

export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=120
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/ios-network-conditions"
rm -rf "$work"
mkdir -p "$work"
# The terminal bench builds cmux-tui, whose ghostty-vt-sys compiles libghostty-vt from the
# ghostty-next submodule; a CI checkout leaves it empty.
git submodule update --init --depth 1 ghostty-next >/dev/null
fetch_url="${IOS_NETCOND_FETCH_URL:-$(git remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)}"
echo "NETCOND-MACHINE host=$(hostname) os=$(uname -sr) cores=$(getconf _NPROCESSORS_ONLN) rev=$(git rev-parse HEAD) before=${before:-none} load=\"$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg)\""

# The harness files a before= tree gets when it predates them.
harness_files=(
  cmux-tui/crates/cmux-fault/src/shaper.rs
  cmux-tui/crates/cmux-fault/src/lib.rs
  cmux-tui/crates/cmux-fault/Cargo.toml
  cmux-tui/crates/cmux-fault/link-profiles.json
  cmux-tui/crates/cmux-tui/tests/mobile_link_conditions.rs
  cmux-tui/crates/acpmux/tests/mobile_link_conditions.rs
)
overlay() {  # overlay TREE: the yardstick of this ref laid over TREE.
  local tree="$1" file
  for file in "${harness_files[@]}"; do
    [[ -f "$root/$file" ]] || continue
    mkdir -p "$(dirname "$tree/$file")"
    cp "$root/$file" "$tree/$file"
  done
  for crate in cmux-tui acpmux; do
    local manifest="$tree/cmux-tui/crates/$crate/Cargo.toml"
    grep -q '^cmux-fault' "$manifest" && continue
    python3 - "$manifest" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
marker = "[dev-dependencies]\n"
if marker not in text:
    text += "\n" + marker
text = text.replace(marker, marker + "cmux-fault.workspace = true\n", 1)
open(path, "w").write(text)
PY
  done
}

# bench LABEL TREE SURFACE: one surface's bench in TREE; its NETCOND lines labelled into lines.txt.
bench() {
  local label="$1" tree="$2" surface="$3" crate log code=0
  case "$surface" in terminal) crate=cmux-tui ;; chat) crate=acpmux ;; esac
  [[ -f "$tree/cmux-tui/crates/$crate/tests/mobile_link_conditions.rs" ]] || {
    echo "NETCOND-SKIP $label $surface: no bench file at this ref"; return 0; }
  log="$work/$label-$surface.log"
  local locked=(--locked)
  [[ "$label" == before && -n "${overlaid:-}" ]] && locked=()
  (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$work/target-$label" \
    NETCOND_PROFILES="$profiles" NETCOND_SCALES="$scales" NETCOND_RUNS="$n" NETCOND_SEED_BASE="$seed" \
    cargo test --release ${locked[@]+"${locked[@]}"} -p "$crate" --test mobile_link_conditions -- \
      --ignored --nocapture --test-threads 1 >"$log" 2>&1) || code=$?
  sed -n "s/^NETCOND /$label /p" "$log" >>"$work/lines.txt"
  grep '^NETCOND-ERROR' "$log" | sed "s/^/$label /" || true
  echo "NETCOND-STATUS $label $surface exit=$code log=$log"
  if (( code != 0 )); then
    tail -n 40 "$log" | sed "s/^/NETCOND-LOG $label $surface /"
    return 1
  fi
}

: >"$work/lines.txt"
status=0
IFS=, read -r -a surface_list <<<"$surfaces"
if [[ -n "$before" ]]; then
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
  git fetch -q ${depth[@]+"${depth[@]}"} "$fetch_url" "$before"
  git worktree add -q --detach "$work/before-src" "$before"
  trap 'git -C "$root" worktree remove --force "$work/before-src" 2>/dev/null || true' EXIT
  git -C "$work/before-src" submodule update --init --depth 1 ghostty-next >/dev/null
  [[ -f "$work/before-src/cmux-tui/crates/cmux-fault/src/shaper.rs" ]] || overlaid=1
  [[ -n "${overlaid:-}" ]] && { overlay "$work/before-src"; echo "NETCOND-OVERLAY before=$before: the harness files of $(git rev-parse HEAD) laid over it"; }
  for surface in "${surface_list[@]}"; do bench before "$work/before-src" "$surface" || status=3; done
fi
for surface in "${surface_list[@]}"; do bench after "$root" "$surface" || status=1; done

python3 "$root/scripts/measure/ios-network-conditions-report.py" "$work/lines.txt" \
  --json "$work/report.json" --markdown "$work/report.md" ${before:+--before "$before"} --after "$(git rev-parse HEAD)"
sed 's/^/NETCOND-TABLE /' "$work/report.md"
exit "$status"
