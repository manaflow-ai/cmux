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
# Local, without cmux-ci: scripts/measure/ios-network-conditions.sh [args] (needs cargo).
set -euo pipefail
trap 'echo "ios-network-conditions.sh: line $LINENO exited $? ($BASH_COMMAND)" >&2' ERR

before="" after="" mode=links duress_profiles="lte,lossy-3" n=5 profiles="" surfaces="terminal,chat" scales="1x,10x,100x" seed=0 relay=""
for kv in "$@"; do
  case "$kv" in
    before=*) before="${kv#*=}" ;;
    after=*) after="${kv#*=}" ;;
    mode=*) mode="${kv#*=}" ;;
    duress_profiles=*) duress_profiles="${kv#*=}" ;;
    n=*) n="${kv#*=}" ;;
    profiles=*) profiles="${kv#*=}" ;;
    surfaces=*) surfaces="${kv#*=}" ;;
    scales=*) scales="${kv#*=}" ;;
    seed=*) seed="${kv#*=}" ;;
    relay=*) relay="${kv#*=}" ;;
    *) echo "ios-network-conditions.sh: unknown arg '$kv' (before=, after=, mode=, duress_profiles=, n=, profiles=, surfaces=, scales=, seed=, relay=)" >&2; exit 2 ;;
  esac
done
[[ -z "$before" || "$before" =~ ^[0-9a-f]{40}$ ]] || { echo "ios-network-conditions.sh: before= is a 40-character SHA" >&2; exit 2; }
[[ -z "$after" || "$after" =~ ^[0-9a-f]{40}$ ]] || { echo "ios-network-conditions.sh: after= is a 40-character SHA" >&2; exit 2; }
[[ "$mode" == links || "$mode" == duress ]] || { echo "ios-network-conditions.sh: mode=links or mode=duress" >&2; exit 2; }
[[ "$duress_profiles" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { echo "ios-network-conditions.sh: duress_profiles=NAME,..." >&2; exit 2; }
[[ "$n" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "ios-network-conditions.sh: n is 1-999" >&2; exit 2; }
[[ "$seed" =~ ^[0-9]{1,9}$ ]] || { echo "ios-network-conditions.sh: seed is a number" >&2; exit 2; }
[[ "$surfaces" =~ ^(terminal|chat)(,(terminal|chat))?$ ]] || { echo "ios-network-conditions.sh: surfaces=terminal,chat" >&2; exit 2; }
[[ "$scales" =~ ^[0-9]+x(,[0-9]+x)*$ ]] || { echo "ios-network-conditions.sh: scales=1x,10x,100x" >&2; exit 2; }
[[ -z "$profiles" || "$profiles" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || { echo "ios-network-conditions.sh: profiles=NAME,..." >&2; exit 2; }
[[ -z "$relay" || "$relay" =~ ^[a-z0-9-]+$ ]] || { echo "ios-network-conditions.sh: relay=NAME (one link profile)" >&2; exit 2; }

export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=120
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
echo "NETCOND-MACHINE host=$(hostname) os=$(uname -sr) cores=$(getconf _NPROCESSORS_ONLN) rev=$(git rev-parse HEAD) before=${before:-none} after=${after:-this} mode=$mode load=\"$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg)\""

# The harness files a before= tree gets when it predates them.
harness_files=(
  cmux-tui/crates/cmux-fault/src/shaper.rs
  cmux-tui/crates/cmux-fault/src/shaper/udp.rs
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
  [[ "$tree" != "$root" && "$overlaid" == *" $label "* ]] && locked=()
  local filter=()
  [[ "$mode" == duress && "$surface" == terminal ]] && filter=(--exact open_path_under_duress)
  [[ "$mode" == links && "$surface" == terminal ]] && filter=(--exact terminal_attach_under_link_profiles)
  # One target directory for every leg: the dependencies build once.
  (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$work/target" \
    NETCOND_PROFILES="$profiles" NETCOND_SCALES="$scales" NETCOND_RUNS="$n" NETCOND_SEED_BASE="$seed" NETCOND_RELAY="$relay" \
    NETCOND_DURESS_PROFILES="$duress_profiles" \
    cargo test --release ${locked[@]+"${locked[@]}"} -p "$crate" --test mobile_link_conditions -- \
      ${filter[@]+"${filter[@]}"} --ignored --nocapture --test-threads 1 2>&1 | tee "$log" |
    # Live as they come, so a run cut at its deadline still shows how far it got.
    { sed -un -e "s/^NETCOND /NETCOND-LIVE $label /p" -e "s/^netcond: /NETCOND-PROGRESS $label /p" || true; }) || code=$?
  sed -n "s/^NETCOND /$label /p" "$log" >>"$work/lines.txt"
  grep -E '^NETCOND-(ERROR|FIXTURE)' "$log" | sed "s/^/$label /" || true
  echo "NETCOND-STATUS $label $surface exit=$code log=$log"
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
  git rev-parse --verify -q "$sha^{commit}" >/dev/null || git fetch -q ${depth[@]+"${depth[@]}"} "$fetch_url" "$sha"
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
sed 's/^/NETCOND-TABLE /' "$work/report.md"
# cmux-test (lane-gh ci --artifact): the report and the logs come back as the run's artifact.
if [[ -n "${FAST_CHECKS_OUT:-}" ]]; then
  mkdir -p "$FAST_CHECKS_OUT"
  cp "$work/report.json" "$work/report.md" "$work/lines.txt" "$work"/*.log "$FAST_CHECKS_OUT/" 2>/dev/null || true
fi
exit "$status"
