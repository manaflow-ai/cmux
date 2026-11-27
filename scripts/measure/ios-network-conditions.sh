#!/usr/bin/env bash
# The iPhone app's surfaces under bad links: time to first content, time to interactive, the
# visible gap after a drop, and bytes and round trips to first content, per link profile, surface,
# cold/warm/reconnect and history scale (1x, 10x, 100x), p50 and p95 over n runs. Every mobile
# speed fix shows its before and after from this one command:
#
#   cmux-ci run --class exclusive --label measure --script scripts/measure/ios-network-conditions.sh \
#     --ref SHA [--arg before=SHA] [--arg n=5] [--arg profiles=lte,elevator-30s] \
#     [--arg surfaces=terminal,chat] [--arg scales=1x,10x,100x] [--arg seed=0] [--arg relay=relay-80] \
#     --artifact .build/ios-network-conditions/report.json --timeout 7200
#
# Headless leg (Linux or Mac, no simulator): real daemons behind cmux-fault's seeded link shaper
# (cmux-tui/crates/cmux-fault/src/shaper.rs), with the link rows in
# cmux-tui/crates/cmux-fault/link-profiles.json (named, versioned, each citing its source):
#   terminal: cmux-tui/crates/cmux-tui/tests/mobile_link_conditions.rs (the real cmux-tui daemon,
#     the phone's `daemon` service requests: set-client-info, identify, attach-surface, send);
#   chat: cmux-tui/crates/acpmux/tests/mobile_link_conditions.rs (the real acpmux, the phone's
#     `acpmux` service requests: _acpmux/watch, _acpmux/attach, afterSeq on reconnect).
# relay=NAME measures a Cloud machine as the peer: that link profile is a second shaped hop behind
# the phone's link (the relay between the signed-in Mac and the machine), and rows read
# `lte@1+relay-80@1`. Without it the peer is the Mac.
#   R1 (time to readable, the chat surface in mode=links and mode=duress):
#     cmux-tui/crates/cmux-mobile-core/tests/read_first_r1.rs (the Agent Chats first page read and
#     decoded from the phone's own read-first store with the link cut; profile no-link@1).
#   transcript (R1 of one agent chat, mode=links and mode=duress, macOS only):
#     cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/TranscriptReadFirstR1Bench.swift (tap
#     to the first frame of a kept chat from AgentTranscriptCache's disk entry, link cut, through
#     the real AcpmuxHub source and AgentChatStore; rows `transcript | no-link@1 | cold|warm | Nx |
#     r1_ms`). It needs swift test with the CmuxMobileLinkFFI xcframework, so it runs on a Mac
#     (cmux-ci run --os macos ... --arg surfaces=transcript); on Linux it prints NETCOND-SKIP. Until
#     this script is on the measurement list at a PR's ref, the same bench runs alone through
#     swift-test-bench.sh: --ref FEAT_TIP --arg cmux-next-ios/CmuxMobileKit
#     --arg TranscriptReadFirstR1Bench --arg source=PR_HEAD --arg config=release
#     --arg enable=CMUX_TRANSCRIPT_R1_BENCH (mode duress, n=20, 1x/10x/100x).
# Each prints NETCOND lines; ios-network-conditions-report.py makes report.json (profile x surface
# x phase x scale x metric: p50, p95, n) and report.md (the table a PR body pastes, with a before
# column and the change when before= is given).
#
# before=SHA builds the same benches at that ref. A ref older than the harness gets the harness
# files laid over it (the shaper, the profiles, the two bench files and their dev-dependency), so
# the code under test is the ref's and the yardstick is this one. Same worker, same seeds.
# after=SHA builds the after leg at that ref (the harness files of this checkout laid over it the
# same way) instead of this checkout's tree: a PR's head against its merge-base, one yardstick.
#
# mode=duress (Leo, 2026-11-22, ask-bb9c69b84e: "testing under duress"): the terminal surface runs
# open_path_under_duress instead (the Home first window and the terminal reattach, the phone's
# forms per the daemon's identify): an idle fixture (no shaper, no stream, 5 workspaces, 1,000
# scrollback lines) and a loaded daemon (50 workspaces, a 10,000-line terminal with output
# streaming into it while it is measured) unshaped and under the duress profiles
# (duress_profiles=lte,lossy-3). The table flags each duress number past 2x its idle one. The chat
# surface runs its usual bench at the scales given (scales=250x: 5,000 turns, 10,000 messages).
#   cmux-ci test -- bash scripts/measure/ios-network-conditions.sh mode=duress surfaces=terminal \
#     before=MERGE_BASE_SHA after=PR_HEAD_SHA n=5
# mode=send (Leo, 2026-11-24, ask-1124-0818, item 1: "i think we can maybe be more optimistic
# sometimes. it is a bit slow on ios."): the send phase. Per send, tap (the request is written) to
# "visible as sent" as the app defines it today (chat: the Mac's user_message echo for the promptId;
# terminal: the keyed send's answer), through the phone's retry (the same promptId / key again after
# a lost answer), and what the host applied: double and lost sends per 100. Rows: idle, lte,
# lossy-3, link-down (lte, the link drops for 3 s at each tap), duress (lte, a loaded host).
# n= is the sends per row (25 by default in this mode); blackout_ms= the link-down length.
# The attachment row: attach_bytes= the image or video size, attach_rows= its conditions
# (idle,lte,duress by default), attach_sends= its sends per row (20 by default). A large attach
# splits by condition, one run per row, so each run stays inside its step's time limit:
#   cmux-ci test -- bash scripts/measure/ios-network-conditions.sh mode=send surfaces=chat \
#     attach_bytes=170000000 attach_rows=lte attach_sends=20
#   cmux-ci test -- bash scripts/measure/ios-network-conditions.sh mode=send surfaces=chat,terminal n=25
#
# mode=background (Leo, 2026-11-24: "the syncing can arguably happen in the background too, so
# deltas can be sipped and maintained"; cmux-next-ios/design/background-delta-sync.md): the
# time-away table. For each time away (away=1m,10m,1h,8h), load (loads=idle,busy) and profile
# (profiles=, default good-wifi,lte,lossy-3) the Mac produces, while the phone's link is closed,
# what that span produces (simulated: made at once, no real time slept), then the link reopens
# through the shaper and each surface catches up: events_behind, stale_s, catch_up_ms, bytes_down,
# bytes_up, round_trips, cursor_hit, per phone form (phase before = today's: the terminal's full
# replay, the list with no `known` after a cold relaunch, the chat's tail-first attach and its
# confirming read; after = the cursor form: resume_offset + resume_generation, the persisted
# `known`, the chat's newest page; after_bounded = after + resume_max_bytes when the daemon lists
# terminal-resume-bounded-v1). Rows: scale `<away>-<load>`. Loads: idle = nothing running (the
# terminal quiet, a list change every 10 min); busy = one agent streaming (2 KiB/s of build log
# into the terminal, capped at the 4 MiB resume ring + 512 KiB; a list change a minute; a ~1 KB
# chat turn every 2 s, about one record a second, acpmux keeps them all). The terminal surface
# runs background_catch_up_after_time_away (terminal and workspaces rows), chat
# chat_background_catch_up_after_time_away. ios-network-conditions-report.py makes one table.
#   nice scripts/measure/ios-network-conditions.sh mode=background n=5
# IOS_NETCOND_TARGET_DIR=DIR keeps the cargo target directory across runs (default: under .build,
# removed at the start of each run).
# Local, without cmux-ci: scripts/measure/ios-network-conditions.sh [args] (needs cargo).
set -euo pipefail
trap 'echo "ios-network-conditions.sh: line $LINENO exited $? ($BASH_COMMAND)" >&2' ERR

before="" after="" mode=links duress_profiles="lte,lossy-3" n=5 profiles="" surfaces="terminal,chat" scales="1x,10x,100x" seed=0 relay="" blackout_ms=3000 send_rows="idle,lte,lossy-3,link-down,duress" n_given="" away="1m,10m,1h,8h" loads="idle,busy" attach_bytes="" attach_rows="" attach_sends=""
for kv in "$@"; do
  case "$kv" in
    before=*) before="${kv#*=}" ;;
    after=*) after="${kv#*=}" ;;
    mode=*) mode="${kv#*=}" ;;
    duress_profiles=*) duress_profiles="${kv#*=}" ;;
    n=*) n="${kv#*=}"; n_given=1 ;;
    profiles=*) profiles="${kv#*=}" ;;
    surfaces=*) surfaces="${kv#*=}" ;;
    scales=*) scales="${kv#*=}" ;;
    seed=*) seed="${kv#*=}" ;;
    relay=*) relay="${kv#*=}" ;;
    blackout_ms=*) blackout_ms="${kv#*=}" ;;
    send_rows=*) send_rows="${kv#*=}" ;;
    away=*) away="${kv#*=}" ;;
    loads=*) loads="${kv#*=}" ;;
    attach_bytes=*) attach_bytes="${kv#*=}" ;;
    attach_rows=*) attach_rows="${kv#*=}" ;;
    attach_sends=*) attach_sends="${kv#*=}" ;;
    *) echo "ios-network-conditions.sh: unknown arg '$kv' (before=, after=, mode=, duress_profiles=, n=, profiles=, surfaces=, scales=, seed=, relay=, blackout_ms=, send_rows=, away=, loads=, attach_bytes=, attach_rows=, attach_sends=)" >&2; exit 2 ;;
  esac
done
[[ -z "$before" || "$before" =~ ^[0-9a-f]{40}$ ]] || { echo "ios-network-conditions.sh: before= is a 40-character SHA" >&2; exit 2; }
[[ -z "$after" || "$after" =~ ^[0-9a-f]{40}$ ]] || { echo "ios-network-conditions.sh: after= is a 40-character SHA" >&2; exit 2; }
[[ "$mode" == links || "$mode" == duress || "$mode" == send || "$mode" == background ]] || { echo "ios-network-conditions.sh: mode=links, mode=duress, mode=send or mode=background" >&2; exit 2; }
[[ "$away" =~ ^[0-9]+[smh](,[0-9]+[smh])*$ ]] || { echo "ios-network-conditions.sh: away=1m,10m,1h,8h" >&2; exit 2; }
[[ "$loads" =~ ^(idle|busy)(,(idle|busy))?$ ]] || { echo "ios-network-conditions.sh: loads=idle,busy" >&2; exit 2; }
[[ "$mode" != background || -n "$profiles" ]] || profiles="good-wifi,lte,lossy-3"
[[ "$duress_profiles" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { echo "ios-network-conditions.sh: duress_profiles=NAME,..." >&2; exit 2; }
[[ "$mode" == send && -z "$n_given" ]] && n=25
[[ "$n" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "ios-network-conditions.sh: n is 1-999" >&2; exit 2; }
[[ "$seed" =~ ^[0-9]{1,9}$ ]] || { echo "ios-network-conditions.sh: seed is a number" >&2; exit 2; }
[[ "$surfaces" =~ ^(terminal|chat|transcript)(,(terminal|chat|transcript)){0,2}$ ]] || { echo "ios-network-conditions.sh: surfaces=terminal,chat,transcript" >&2; exit 2; }
[[ "$scales" =~ ^[0-9]+x(,[0-9]+x)*$ ]] || { echo "ios-network-conditions.sh: scales=1x,10x,100x" >&2; exit 2; }
[[ -z "$profiles" || "$profiles" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { echo "ios-network-conditions.sh: profiles=NAME,..." >&2; exit 2; }
[[ -z "$attach_bytes" || "$attach_bytes" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "ios-network-conditions.sh: attach_bytes is the photo size in bytes (default 5242880)" >&2; exit 2; }
[[ -z "$attach_rows" || "$attach_rows" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { echo "ios-network-conditions.sh: attach_rows=idle,lte,duress" >&2; exit 2; }
[[ -z "$attach_sends" || "$attach_sends" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "ios-network-conditions.sh: attach_sends is 1-999 (default 20)" >&2; exit 2; }
[[ -z "$relay" || "$relay" =~ ^[a-z0-9-]+$ ]] || { echo "ios-network-conditions.sh: relay=NAME (one link profile)" >&2; exit 2; }

export GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=120
root="$(git rev-parse --show-toplevel)"
cd "$root"
# A bare runner (cmux-ci test): the pinned Rust and Zig and the native build tools, as
# mobile-open-path.sh and infinite-items-linux.sh get them.
export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v zig >/dev/null && [ -z "${ZIG:-}${CMUX_ZIG:-}" ]; then
  git submodule update --init --depth 1 ghostty-next >/dev/null
  zig_env="$(mktemp)"
  GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh
  zig_line="$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true)"
  rm -f "$zig_env"
  [ -z "$zig_line" ] || export "$zig_line"
fi
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
command -v cargo >/dev/null || { echo "ios-network-conditions.sh: needs cargo on PATH; run it through cmux-ci run" >&2; exit 2; }
work="$root/.build/ios-network-conditions"
rm -rf "$work"
mkdir -p "$work"
# The terminal bench builds cmux-tui, whose ghostty-vt-sys compiles libghostty-vt from the
# ghostty-next submodule; a CI checkout leaves it empty.
git submodule update --init --depth 1 ghostty-next >/dev/null
fetch_url="${IOS_NETCOND_FETCH_URL:-$(git remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)}"
machine="host=$(hostname) os=$(uname -sr) cores=$(getconf _NPROCESSORS_ONLN) rev=$(git rev-parse HEAD) before=${before:-none} after=${after:-this} mode=$mode load=\"$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg)\""
echo "NETCOND-MACHINE $machine"
# Timing canary (docs/handbook/timing-on-a-busy-host.md, fix 3): spin 20 ms of CPU and print the
# wall time it took over the CPU time it got, median of 5. 1.00 = a free core; 2.00 = every CPU-bound
# step took twice as long. Probed before and after the benches, never during them.
canary() {
  python3 -I -c 'import statistics, time
def spin():
    w, c = time.perf_counter(), time.process_time()
    while time.process_time() - c < 0.02:
        pass
    return (time.perf_counter() - w) / (time.process_time() - c)
print("%.2f" % statistics.median(spin() for _ in range(5)))' 2>/dev/null || echo "n/a"
}
canary_before=$(canary)
echo "NETCOND-CANARY before_benches=$canary_before"

# The harness files a before= tree gets when it predates them.
harness_files=(
  cmux-tui/crates/cmux-mobile-core/tests/read_first_r1.rs
  cmux-tui/crates/cmux-fault/src/shaper.rs
  cmux-tui/crates/cmux-fault/src/shaper/udp.rs
  cmux-tui/crates/cmux-fault/src/lib.rs
  cmux-tui/crates/cmux-fault/Cargo.toml
  cmux-tui/crates/cmux-fault/link-profiles.json
  cmux-tui/crates/cmux-tui/tests/mobile_link_conditions.rs
  cmux-tui/crates/acpmux/tests/mobile_link_conditions.rs
  cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/TranscriptReadFirstR1Bench.swift
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

# r1 LABEL TREE: R1 time to readable, the chat list from the phone's own store with the link cut
# (cmux-mobile-core tests/read_first_r1.rs); its NETCOND lines labelled into lines.txt.
r1() {
  local label="$1" tree="$2" log="$work/$1-r1.log" code=0 locked=(--locked)
  [[ -f "$tree/cmux-tui/crates/cmux-mobile-core/tests/read_first_r1.rs" ]] || {
    echo "NETCOND-SKIP $label r1: no read_first_r1 bench at this ref"; return 0; }
  [[ "$tree" != "$root" && "$overlaid" == *" $label "* ]] && locked=()
  (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="${IOS_NETCOND_TARGET_DIR:-$work/target}" \
    NETCOND_MODE="$mode" NETCOND_SCALES="$scales" NETCOND_RUNS="$n" NETCOND_SEED_BASE="$seed" \
    cargo test --release ${locked[@]+"${locked[@]}"} -p cmux-mobile-core --test read_first_r1 -- \
      --ignored --nocapture --test-threads 1 >"$log" 2>&1) || code=$?
  sed -n "s/^NETCOND /$label /p" "$log" >>"$work/lines.txt"
  grep -E '^NETCOND-ERROR' "$log" | sed "s/^/$label /" || true
  echo "NETCOND-STATUS $label r1 exit=$code log=$log"
  (( code == 0 )) || { tail -n 40 "$log" | sed "s/^/NETCOND-LOG $label r1 /"; return 1; }
}

# transcript LABEL TREE: R1 of one kept agent chat from AgentTranscriptCache with the link cut
# (CmuxMobileLiveTests TranscriptReadFirstR1Bench, swift test on macOS); NETCOND lines into lines.txt.
transcript() {
  local label="$1" tree="$2" log="$work/$1-transcript.log" code=0
  local bench=cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/TranscriptReadFirstR1Bench.swift
  [[ "$mode" == links || "$mode" == duress ]] || { echo "NETCOND-SKIP $label transcript: mode=links or mode=duress only"; return 0; }
  [[ "$(uname -s)" == Darwin ]] || { echo "NETCOND-SKIP $label transcript: needs swift test on macOS (CmuxMobileLive)"; return 0; }
  [[ -f "$tree/$bench" ]] || { echo "NETCOND-SKIP $label transcript: no TranscriptReadFirstR1Bench at this ref"; return 0; }
  # swift-test-bench.sh's release suite build: @testable needs -enable-testing, DEBUG stays defined,
  # and the Xcode 26.6 optimizer's CopyPropagation crash is avoided.
  local release=(-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=copy-propagation)
  # CmuxMobileKit names a local xcframework (a binaryTarget) that SwiftPM needs even on macOS;
  # it is built, not checked in (as swift-test-bench.sh builds it).
  (cd "$tree" && JOBS="$(sysctl -n hw.ncpu)" bash cmux-next-ios/rust/scripts/build-xcframework.sh) >"$log" 2>&1 || code=$?
  if (( code == 0 )); then
    (cd "$tree" && swift build "${release[@]}" --package-path cmux-next-ios/CmuxMobileKit --build-tests) >>"$log" 2>&1 || code=$?
  fi
  if (( code == 0 )); then
    (cd "$tree" && CMUX_TRANSCRIPT_R1_BENCH=1 NETCOND_MODE="$mode" NETCOND_SCALES="$scales" NETCOND_RUNS="$n" \
      NETCOND_SEED_BASE="$seed" swift test "${release[@]}" --package-path cmux-next-ios/CmuxMobileKit --skip-build \
      --filter TranscriptReadFirstR1Bench 2>&1 | tee -a "$log" |
      { sed -un "s/^NETCOND /NETCOND-LIVE $label /p" || true; }) || code=$?
  fi
  sed -n "s/^NETCOND /$label /p" "$log" >>"$work/lines.txt"
  grep -E '^NETCOND-ERROR' "$log" | sed "s/^/$label /" || true
  echo "NETCOND-STATUS $label transcript exit=$code log=$log"
  (( code == 0 )) || { tail -n 40 "$log" | sed "s/^/NETCOND-LOG $label transcript /"; return 1; }
}

# bench LABEL TREE SURFACE: one surface's bench in TREE; its NETCOND lines labelled into lines.txt.
bench() {
  local label="$1" tree="$2" surface="$3" crate log code=0
  [[ "$surface" == transcript ]] && { transcript "$label" "$tree"; return; }
  case "$surface" in terminal) crate=cmux-tui ;; chat) crate=acpmux ;; esac
  [[ -f "$tree/cmux-tui/crates/$crate/tests/mobile_link_conditions.rs" ]] || {
    echo "NETCOND-SKIP $label $surface: no bench file at this ref"; return 0; }
  log="$work/$label-$surface.log"
  local locked=(--locked)
  [[ "$tree" != "$root" && "$overlaid" == *" $label "* ]] && locked=()
  local filter=()
  [[ "$mode" == duress && "$surface" == terminal ]] && filter=(--exact open_path_under_duress)
  [[ "$mode" == links && "$surface" == terminal ]] && filter=(--exact terminal_attach_under_link_profiles)
  # The send phase and the time-away bench have their own tests; the other modes skip them.
  [[ "$mode" != send && "$mode" != background && "$surface" == chat ]] && filter=(--skip chat_send_under_link_conditions --skip chat_attach_under_link_conditions --skip chat_background_catch_up_after_time_away)
  [[ "$mode" == send && "$surface" == terminal ]] && filter=(--exact terminal_send_under_link_conditions)
  [[ "$mode" == send && "$surface" == chat ]] && filter=(--exact chat_send_under_link_conditions chat_attach_under_link_conditions)
  [[ "$mode" == background && "$surface" == terminal ]] && filter=(--exact background_catch_up_after_time_away)
  [[ "$mode" == background && "$surface" == chat ]] && filter=(--exact chat_background_catch_up_after_time_away)
  # One target directory for every leg: the dependencies build once.
  # env, not a bare prefix: a ${x:+NAME=v} expansion is never an assignment, bash runs it as the command.
  (cd "$tree/cmux-tui" && env CARGO_TARGET_DIR="${IOS_NETCOND_TARGET_DIR:-$work/target}" \
    NETCOND_PROFILES="$profiles" NETCOND_SCALES="$scales" NETCOND_RUNS="$n" NETCOND_SEED_BASE="$seed" NETCOND_RELAY="$relay" \
    NETCOND_DURESS_PROFILES="$duress_profiles" NETCOND_SENDS="$n" NETCOND_SEND_BLACKOUT_MS="$blackout_ms" \
    NETCOND_SEND_ROWS="$send_rows" NETCOND_AWAY="$away" NETCOND_LOADS="$loads" ${attach_bytes:+NETCOND_ATTACH_BYTES="$attach_bytes"} \
    ${attach_rows:+NETCOND_ATTACH_ROWS="$attach_rows"} ${attach_sends:+NETCOND_ATTACH_SENDS="$attach_sends"} \
    cargo test --release ${locked[@]+"${locked[@]}"} -p "$crate" --test mobile_link_conditions -- \
      ${filter[@]+"${filter[@]}"} --ignored --nocapture --test-threads 1 2>&1 | tee "$log" |
    # Live as they come, so a run cut at its deadline still shows how far it got.
    { sed -un -e "s/^NETCOND /NETCOND-LIVE $label /p" -e "s/^netcond: /NETCOND-PROGRESS $label /p" || true; }) || code=$?
  sed -n "s/^NETCOND /$label /p" "$log" >>"$work/lines.txt"
  grep -E '^NETCOND-(ERROR|FIXTURE|SKIP)' "$log" | sed "s/^/$label /" || true
  echo "NETCOND-STATUS $label $surface exit=$code log=$log"
  [[ "$surface" == chat && ( "$mode" == links || "$mode" == duress ) ]] && { r1 "$label" "$tree" || code=1; }
  if (( code != 0 )); then
    tail -n 40 "$log" | sed "s/^/NETCOND-LOG $label $surface /"
    return 1
  fi
}

: >"$work/lines.txt"
status=0
IFS=, read -r -a surface_list <<<"$surfaces"
# Labels whose tree got this checkout's harness files, space-separated: a plain string, since macOS
# runs /bin/bash 3.2, which has no associative arrays (declare -A).
overlaid=" "
cleanup=()
trap 'for tree in ${cleanup[@]+"${cleanup[@]}"}; do git -C "$root" worktree remove --force "$tree" 2>/dev/null || true; done' EXIT
# checkout LABEL SHA: the ref's tree at $work/LABEL-src, with this checkout's harness files laid over
# it when they are missing there or differ (the code under test is the ref's, the yardstick this one).
checkout() {
  local label="$1" sha="$2" tree="$work/$1-src" file depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
  git rev-parse --verify -q "$sha^{commit}" >/dev/null || git fetch --no-recurse-submodules -q ${depth[@]+"${depth[@]}"} "$fetch_url" "$sha"
  git worktree add -q --detach "$tree" "$sha"
  cleanup+=("$tree")
  git -C "$tree" submodule update --init --depth 1 ghostty-next >/dev/null
  for file in "${harness_files[@]}"; do
    [[ -f "$root/$file" ]] || continue
    cmp -s "$root/$file" "$tree/$file" || { [[ "$overlaid" == *" $label "* ]] || overlaid+="$label "; }
  done
  if [[ "$overlaid" == *" $label "* ]]; then
    overlay "$tree"
    echo "NETCOND-OVERLAY $label=$sha: the harness files of $(git rev-parse HEAD) laid over it"
  fi
}
if [[ -n "$before" ]]; then
  checkout before "$before"
  for surface in "${surface_list[@]}"; do bench before "$work/before-src" "$surface" || status=3; done
fi
after_tree="$root"
if [[ -n "$after" ]]; then
  checkout after "$after"
  after_tree="$work/after-src"
fi
for surface in "${surface_list[@]}"; do bench after "$after_tree" "$surface" || status=1; done

python3 "$root/scripts/measure/ios-network-conditions-report.py" "$work/lines.txt" \
  --json "$work/report.json" --markdown "$work/report.md" ${before:+--before "$before"} --after "${after:-$(git rev-parse HEAD)}"
canary_after=$(canary)
echo "NETCOND-CANARY after_benches=$canary_after"
{
  echo
  echo "Machine: $machine"
  echo "Canary (wall/cpu of a 20 ms spin, 1.00 = a free core): before the benches $canary_before, after $canary_after"
} >>"$work/report.md"
sed 's/^/NETCOND-TABLE /' "$work/report.md"
# cmux-test (lane-gh ci --artifact): the report and the logs come back as the run's artifact.
if [[ -n "${FAST_CHECKS_OUT:-}" ]]; then
  mkdir -p "$FAST_CHECKS_OUT"
  cp "$work/report.json" "$work/report.md" "$work/lines.txt" "$work"/*.log "$FAST_CHECKS_OUT/" 2>/dev/null || true
fi
exit "$status"
