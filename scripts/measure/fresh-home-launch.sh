#!/usr/bin/env bash
# A fresh-home launch of any commit's cmux NEXT app on a fleet worker with a console session: the
# check a PR that changes Chief code lands on ("a fresh-home launch passes on a fleet Mac"), which
# until now only a published nightly DMG got (nightly-next-launch-smoke.yml).
#   cmux-ci run --class exclusive --label measure --label gui-session-v1 \
#     --script scripts/measure/fresh-home-launch.sh --ref <this script's sha> [--arg=ref=<sha to launch>] \
#     --artifact .build/fresh-home-launch/report.tgz --timeout 3600
#   --arg=ref=SHA   the commit whose app to build and launch (40 hex; default: this checkout). It is
#                   built in its own worktree, so a PR head that predates this script can be launched.
#   --arg=seconds=S how long the app must stay up (default 30)
#   --arg=load=1    launch and hold the app under qos-load-bench.sh's agent-like load (CPU spinners
#                   past every core, dd writers, find storms, readers), started once the build is done and
#                   stopped when the smoke ends: "a busy machine makes things slower, never makes them
#                   fail" (cmuxterm-hq#7063).
#   --arg=startup=S how long Home may take to render (default 90; the smoke's --startup-timeout)
# It builds a tagged Debug app (scripts/reload.sh, as crash-gate.sh does) and runs
# scripts/ci/fresh_home_launch_smoke.py --app on it in the console session: an empty HOME, no
# defaults, Home must render and the app must stay up. The verdict is the smoke's: exit 0 passed,
# 1 crashed or never rendered Home, 3 could not run. Prints FRESH-HOME lines.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
here="$PWD"
ref="" seconds=30 load=0 startup=90
for arg in "$@"; do
  case "$arg" in
    ref=*) ref="${arg#ref=}" ;;
    seconds=*) seconds="${arg#seconds=}" ;;
    load=*) load="${arg#load=}" ;;
    startup=*) startup="${arg#startup=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "seconds= must be a number" >&2; exit 2; }
[[ "$startup" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "startup= must be a number" >&2; exit 2; }
[[ "$load" == 0 || "$load" == 1 ]] || { echo "load= must be 0 or 1" >&2; exit 2; }
# The load's workers, each in its own process group (set -m in start_load), so stop_load ends their
# dd and find children too. Only this script's own jobs are signalled.
load_pgids=() load_dir=""
stop_load() {
  for g in ${load_pgids[@]+"${load_pgids[@]}"}; do kill -TERM -- "-$g" 2>/dev/null; done
  wait 2>/dev/null; load_pgids=()
  [ -n "$load_dir" ] && rm -rf "$load_dir"; load_dir=""
}
# A cancelled or timed-out step gets SIGTERM, which skips an EXIT trap unless the signal is trapped:
# exit on it so the EXIT traps below stop the load (its workers are in their own process groups, so
# the step's own group signal never reaches them) and remove the worktree.
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
out="$here/.build/fresh-home-launch"
rm -rf "$out" && mkdir -p "$out"
src="$here"
if [[ -n "$ref" && "$ref" != "$(git rev-parse HEAD)" ]]; then
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "ref= must be a 40-hex commit" >&2; exit 2; }
  # A fleet step's checkout has no origin: try it, then the worker's mirror, then GitHub (a PR head
  # is fetchable there by sha).
  if ! git cat-file -e "$ref^{commit}" 2>/dev/null; then
    fetched=false
    # --depth only on an already-shallow checkout: in a full clone it would truncate history for
    # every worktree sharing it (tests/test_ci_no_shallow_dev_fetch.py).
    depth=()
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
    for remote in origin /Users/Shared/cmux-build-fleet/git/cmux.git https://github.com/manaflow-ai/cmux.git; do
      git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "$ref" 2>/dev/null && { fetched=true; break; }
    done
    $fetched || { echo "cannot fetch $ref" >&2; exit 3; }
  fi
  scratch="$(mktemp -d)"
  src="$scratch/src"
  git worktree add --quiet --detach "$src" "$ref" || { rm -rf "$scratch"; exit 3; }
  trap 'stop_load; git -C "$here" worktree remove --force "$src" >/dev/null 2>&1; rm -rf "$scratch"' EXIT
fi
cd "$src"
sha="$(git rev-parse HEAD)"
tag="freshhome-${sha:0:8}"
echo "FRESH-HOME host $(hostname -s) macOS $(sw_vers -productVersion) commit $sha"
# A fleet step checks out no submodules: the app build needs Ghostty's headers and the ghostty-next
# tree, and GhosttyKit.xcframework (a prebuilt download), as crash-gate.sh fetches them.
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub" || exit 3
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh || exit 3
fi
work="$(mktemp -d)"
# Steps run with a per-step HOME; bun and node for the Debug build's web bundles live under the
# account's real home (as crash-gate.sh and tab-switch.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" "$account_home/.cargo/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
# Rust's toolchains are the account's too: with the step's HOME, rustup finds no default toolchain
# (the build's cmux-cua and the cmux-tui client set both need it).
if [ -n "$account_home" ]; then
  [ -z "${RUSTUP_HOME:-}" ] && [ -d "$account_home/.rustup" ] && export RUSTUP_HOME="$account_home/.rustup"
  [ -z "${CARGO_HOME:-}" ] && [ -d "$account_home/.cargo" ] && export CARGO_HOME="$account_home/.cargo"
fi
RUNNER_TEMP="$work" GITHUB_PATH="$work/bun-path" ./scripts/cmux-next/private-bun.sh || exit 3
PATH="$(tail -n 1 "$work/bun-path"):$PATH"
export PATH
# A PR head's cmux-tui tree is never published (only trusted feat-cmux-next pushes publish), and
# the base can run hours behind: build the client set here instead of waiting 45 min for a tree
# that will not come, as reload.sh does for nx-remote builds (CMUX_TUI_CLIENT_LOCAL).
if [[ -z "${CMUX_TUI_CLIENT_LOCAL:-}" ]] && ! ./scripts/cmux-next/pin-cmux-tui.sh probe 2>/dev/null | grep -q ': ready ('; then
  echo "FRESH-HOME cmux-tui tree not published: building the client set on this host"
  # Cargo's target survives this scratch worktree, so the next launch compiles incrementally
  # (the builder makes its output under cmux-tui/target, which a fresh worktree lacks).
  export CMUX_TUI_CLIENT_TARGET_DIR="${CMUX_TUI_CLIENT_TARGET_DIR:-${CI_SHARED_CACHE_DIR:-/Users/Shared/cmux-build-fleet/cache}/fresh-home-launch/cmux-tui-target}"
  mkdir -p "$CMUX_TUI_CLIENT_TARGET_DIR" cmux-tui/target
  # CI=1: this is a fleet step, where the builder may run Cargo (never on a developer Mac).
  # Its progress also goes to the step's log: a silent step looks hung and the controller stops it.
  CMUX_TUI_CLIENT_LOCAL="$(CI=1 ./scripts/cmux-next/build-cmux-tui-client.sh --print-path 2> >(tee "$out/cmux-tui-build.log" >&2))" || {
    echo "FRESH-HOME cannot run: building cmux-tui failed" >&2
    tail -n 40 "$out/cmux-tui-build.log" >&2
    tar -czf "$out/report.tgz" -C "$out" cmux-tui-build.log
    exit 3
  }
  export CMUX_TUI_CLIENT_LOCAL
fi
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links >"$out/reload.log" 2>&1
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "FRESH-HOME cannot run: the tagged build printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2
  tar -czf "$out/report.tgz" -C "$out" reload.log
  exit 3
fi
# The harness and the teardown come from this script's checkout, never the launched ref's (which
# may predate them); the teardown also runs when the step is killed mid-smoke.
trap 'stop_load; python3 "$here/scripts/cmux-next/tag_teardown.py" "$app" >/dev/null 2>&1; [ -n "${scratch:-}" ] && { git -C "$here" worktree remove --force "$src" >/dev/null 2>&1; rm -rf "$scratch"; }' EXIT
if [ "$load" = 1 ]; then
  # The same load as qos-load-bench.sh's load_default cell, at the default priority, from this
  # script's checkout. Started after the build so the build's own time is not what it measures.
  load_dir="$(mktemp -d)"
  cc -O2 -o "$load_dir/spin" "$here/scripts/measure/qos-load-bench/spin.c" || exit 3
  # The readers' tree (2000 files of 64 KiB, as qos-load-bench.sh's loadtree), in the load's own folder.
  mkdir -p "$load_dir/loadtree"
  for i in $(seq 1 2000); do head -c 65536 /dev/urandom > "$load_dir/loadtree/f$i"; done
  set -m
  start_load() { "$@" & load_pgids+=("$!"); }
  for _ in $(seq 1 $(( $(sysctl -n hw.ncpu) / 4 + 1 ))); do start_load "$load_dir/spin"; done
  for _ in 1 2; do start_load /bin/sh -c 'while :; do dd if=/dev/zero of="$1/w$$" bs=1m count=256 2>/dev/null; rm -f "$1/w$$"; done' sh "$load_dir"; done
  for _ in 1 2; do start_load /bin/sh -c 'while :; do find /System/Library /usr -type f -size +1k >/dev/null 2>&1; done'; done
  for _ in 1 2; do start_load /bin/sh -c 'while :; do cat "$1"/loadtree/f* | shasum >/dev/null; done' sh "$load_dir"; done
  set +m
  sleep 5
  echo "FRESH-HOME load on: $(sysctl -n hw.ncpu) cores, load averages $(uptime | sed 's/.*averages: //')"
fi
python3 -I "$here/scripts/ci/fresh_home_launch_smoke.py" --app "$app" --seconds "$seconds" --startup-timeout "$startup" --out "$out/smoke"
status=$?
if [ "$load" = 1 ]; then
  echo "FRESH-HOME load at the end: load averages $(uptime | sed 's/.*averages: //')"
  stop_load
fi
case $status in 0) verdict=passed ;; 1) verdict=failed ;; *) verdict=cannot-run; status=3 ;; esac
echo "FRESH-HOME verdict $verdict commit $sha load $load (exit $status)"
tar -czf "$out/report.tgz" -C "$out" .
exit $status
