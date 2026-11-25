#!/usr/bin/env bash
# One commit's compile verdict for scripts/ci/head_compile.py (its --check command), on the build fleet.
#
#   head-compile.sh SHA BASE CHECKS
#
# CHECKS is head_compile.py plan's list, comma-separated: "app" submits `cmux-ci compile-check --ref SHA --app
# --release --tests` (the cmux-next app, the FFI it links, and the macOS cmux-tui crates it bundles with their test
# targets, on the Linux pool); "linux" submits `feat-parity-check.sh head-check BASE` (every Cargo.lock in sync,
# then `cargo check --workspace --all-targets --locked` of cmux-tui on Linux). Both run at once; each log is
# printed. Exit 0 when every leg passed, 1 when any leg found a compile error, 75 when no leg was red but one gave
# no verdict (a busy or unreachable fleet: cmux-ci's 3, 69, 75, 76, 124 and the step's own 3), so a busy fleet is
# never a red head.
#
# Env: CMUX_CI_CLIENT (default ~/.local/bin/cmux-ci); HEAD_COMPILE_QUEUE_TIMEOUT (1800 s);
# HEAD_COMPILE_TIMEOUT (2400 s, from the claim).
set -uo pipefail
sha="${1:?sha}" base="${2:?base}" checks="${3:?checks}"
client="${CMUX_CI_CLIENT:-$HOME/.local/bin/cmux-ci}"
queue="${HEAD_COMPILE_QUEUE_TIMEOUT:-1800}"
limit="${HEAD_COMPILE_TIMEOUT:-2400}"
[[ "$sha" =~ ^[0-9a-f]{40}$ && "$base" =~ ^[0-9a-f]{40}$ ]] || { echo "head-compile: SHA and BASE are full commit ids" >&2; exit 2; }
if ! [ -x "$client" ]; then
  echo "head-compile: $client is not installed on ${RUNNER_NAME:-this host}; no verdict"
  exit 75
fi
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
pids=() legs=()
if [[ ",$checks," == *,app,* ]]; then
  "$client" compile-check --ref "$sha" --app --release --tests --timeout "$limit" --queue-timeout "$queue" \
    > "$dir/app.log" 2>&1 &
  pids+=($!) legs+=(app)
fi
if [[ ",$checks," == *,linux,* ]]; then
  "$client" run --class light --script scripts/ci/feat-parity-check.sh --ref "$sha" --arg head-check --arg "$base" \
    --timeout "$limit" --queue-timeout "$queue" --reason "head compile ${sha:0:12} (cmux-next-head-compile.yml)" \
    > "$dir/linux.log" 2>&1 &
  pids+=($!) legs+=(linux)
fi
[ "${#pids[@]}" -gt 0 ] || { echo "head-compile: no check named in '$checks'"; exit 2; }
red=0 unknown=0
for i in "${!pids[@]}"; do
  code=0
  wait "${pids[$i]}" || code=$?
  leg="${legs[$i]}"
  echo "=== ${leg} (${sha:0:12}): exit ${code}"
  cat "$dir/$leg.log"
  case "$code" in
    0) ;;
    1) red=1; echo "head-compile: ${leg} red at ${sha}" ;;
    *) unknown=1; echo "head-compile: ${leg} gave no verdict at ${sha} (exit ${code})" ;;
  esac
done
[ "$red" -eq 0 ] || exit 1
[ "$unknown" -eq 0 ] || exit 75
exit 0
