#!/usr/bin/env bash
# A split-spring A/B in ONE measure step on whichever measure Mac is free: the base commit's app and the head
# commit's app, measured by each commit's own scripts/measure/split-spring.sh in interleaved rounds (base, head, base,
# head, ...) on the same Mac, so the before and after see the same host. No --target-worker and no --label bench:
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/split-ab.sh --ref <this script's sha> \
#     --arg=base=<sha> --arg=head=<sha> [--arg=rounds=2] \
#     --arg=--suite=split-scale --arg=--quick --arg=--vdisplay=120 --arg=--config=bench \
#     --artifact .build/split-ab/report.tgz --timeout 7200
#   base=SHA     arm A, the commit to compare against (40 hex)
#   head=SHA     arm B, the measured commit (40 hex)
#   rounds=N     measurements per arm (default 2, at most 6)
#   anything else goes to both arms' split-spring.sh (--suite=..., --quick, --vdisplay=HZ, --config=..., ...).
# Why (goal instant-splits, 2026-11-28): every splits A/B was pinned --pin-strict to cmux20-bench, the one Mac with the
# `bench` label, so one lane's 12 pins, 6 urgent person steps and 7 per-PR split tables queued 9-16 h for one host
# while the other gui measure Macs took none of them. One step that measures both arms needs no particular Mac.
# Leo, 2026-11-28: "Ok well we can't be letting important rfds like that take breaks unless I put in fleet wide
# pauses, esp when this is stuff that materially improves the app".
# CMUX_MEASURE_PHASE (a build_first measurement, split-spring.sh): `build` builds both arms' apps at light class
# (--build-only pins them in the app cache for 13 h) and exits 80; `measure` measures them from the cache.
# Each arm is its own git worktree at its commit; the worktrees and (outside the build phase) the app-cache entries
# this step made are removed at the end. Output, per round and arm, then per arm and the delta:
#   SPLIT-AB round <arm> <round> rc <N> metrics <count>
#   SPLIT-AB median <arm> <metric> <value>
#   SPLIT-AB delta <metric> base <v> head <v> delta <head - base>
# (scripts/measure/split_ab_summary.py; metrics are split-scale cell/transition/key and perf row/p50|p95.)
# Verdict: exit 0 every round measured, 1 a round failed, 3 none could run, 80 built (build phase).
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
here="$PWD"
base="" head="" rounds=2 arm_args=()
for arg in "$@"; do
  case "$arg" in
    base=*) base="${arg#base=}" ;;
    head=*) head="${arg#head=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    --build-only) echo "split-ab: --build-only is the build phase's (CMUX_MEASURE_PHASE=build), not an argument" >&2; exit 2 ;;
    *) arm_args+=("$arg") ;;
  esac
done
[[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || { echo "split-ab: base= and head= must be 40-hex commits" >&2; exit 2; }
[[ "$rounds" =~ ^[0-9]+$ ]] && (( rounds >= 1 && rounds <= 6 )) || { echo "split-ab: rounds= must be 1 to 6" >&2; exit 2; }
phase="${CMUX_MEASURE_PHASE:-}"
case "$phase" in
  build|measure|"") ;;
  *) echo "split-ab: unknown CMUX_MEASURE_PHASE=$phase (build or measure)" >&2; exit 2 ;;
esac
# The arms read no phase of their own: this script says --build-only (build) or measures from the cache.
unset CMUX_MEASURE_PHASE
[[ "${SPLIT_AB_PARSE_ONLY:-0}" == 1 ]] && { printf 'base=%s head=%s rounds=%s phase=%s args=%s\n' "$base" "$head" "$rounds" "$phase" "${arm_args[*]-}"; exit 0; }
out="$here/.build/split-ab"
rm -rf "$out" && mkdir -p "$out"
# A cancelled or timed-out step gets SIGTERM, which skips an EXIT trap unless the signal is trapped.
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
scratch="" cache_dir="${CI_SHARED_CACHE_DIR:+$CI_SHARED_CACHE_DIR/split-spring-apps}"
cache_before="$( [ -n "$cache_dir" ] && ls -1 "$cache_dir" 2>/dev/null | sort)"
cleanup() {
  local code=$?
  if [ -n "$scratch" ]; then
    for arm in base head; do
      [ -d "$scratch/$arm" ] && git -C "$here" worktree remove --force "$scratch/$arm" >/dev/null 2>&1
    done
    rm -rf "$scratch"
    git -C "$here" worktree prune >/dev/null 2>&1
  fi
  # Only the app-cache entries this step made, never one an earlier step left; the build phase keeps its (pinned) apps
  # for the measure phase.
  if [ "$phase" != build ] && [ -n "$cache_dir" ] && [ -d "$cache_dir" ]; then
    comm -13 <(printf '%s\n' "$cache_before") <(ls -1 "$cache_dir" 2>/dev/null | sort) | sed '/^$/d' |
      while read -r made; do rm -rf "${cache_dir:?}/$made"; done
  fi
  echo "SPLIT-AB disk free after: $(df -h "$here" | awk 'NR==2 {print $4}')"
  exit "$code"
}
trap cleanup EXIT
echo "SPLIT-AB host $(hostname -s) macOS $(sw_vers -productVersion 2>/dev/null) base $base head $head rounds $rounds phase ${phase:-one} args ${arm_args[*]-}"
echo "SPLIT-AB disk free before: $(df -h "$here" | awk 'NR==2 {print $4}')"
# The benches draw only in this account's GUI session: check before building both arms (bench_launch session rule).
if [ "$phase" != build ] && ! session="$(python3 scripts/cmux-next/bench_launch.py session 2>&1)"; then
  echo "SPLIT-AB no-gui-session: $session" >&2
  echo "SPLIT-AB verdict exit 3 base $base head $head rounds $rounds"
  exit 3
fi
# Steps run with a per-step HOME; node and cargo for the app build live under the account's real home, and the
# worker's pinned bun goes back in front of the account's own (chat-typing-ab.sh, step 33bef005).
pinned_bun="$(command -v bun 2>/dev/null || true)"
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin" "$account_home/.cargo/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
if [ -n "$pinned_bun" ]; then
  bun_dir="$(dirname "$pinned_bun")"
  export PATH="$bun_dir:$PATH"
fi
if [ -n "$account_home" ]; then
  [ -z "${RUSTUP_HOME:-}" ] && [ -d "$account_home/.rustup" ] && export RUSTUP_HOME="$account_home/.rustup"
  [ -z "${CARGO_HOME:-}" ] && [ -d "$account_home/.cargo" ] && export CARGO_HOME="$account_home/.cargo"
fi
scratch="$(mktemp -d)"
for arm in base head; do
  ref="$base"; [ "$arm" = head ] && ref="$head"
  # A fleet step's checkout has no origin: try it, then the worker's mirror, then GitHub (a PR head is fetchable by sha).
  if ! git cat-file -e "$ref^{commit}" 2>/dev/null; then
    depth=()
    [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
    for remote in origin /Users/Shared/cmux-build-fleet/git/cmux.git https://github.com/manaflow-ai/cmux.git; do
      git fetch --quiet ${depth[@]+"${depth[@]}"} "$remote" "$ref" 2>/dev/null && break
    done
  fi
  git worktree add --quiet --detach "$scratch/$arm" "$ref" || { echo "SPLIT-AB cannot check out $arm $ref" >&2; exit 3; }
done
if [ "$phase" = build ]; then
  status=80
  for arm in base head; do
    (cd "$scratch/$arm" && bash scripts/measure/split-spring.sh --build-only ${arm_args[@]+"${arm_args[@]}"}) 2>&1 |
      grep -E "^split-spring:|error" | head -n 40
    rc="${PIPESTATUS[0]}"
    echo "SPLIT-AB build $arm rc $rc"
    (( rc == 0 )) || status=1
  done
  echo "SPLIT-AB verdict exit $status (build phase) base $base head $head"
  exit "$status"
fi
for i in $(seq 1 "$rounds"); do
  for arm in base head; do
    mkdir -p "$out/$arm-$i"
    (cd "$scratch/$arm" && bash scripts/measure/split-spring.sh --app-cache ${arm_args[@]+"${arm_args[@]}"}) 2>&1 |
      tee "$out/$arm-$i/log" | grep -E "^split-spring:|SPLIT|first frame|error" | head -n 80
    echo "${PIPESTATUS[0]}" > "$out/$arm-$i/rc"
    for f in report.json perf-gate.json; do
      [ -f "$scratch/$arm/artifacts/split-spring/$f" ] && cp "$scratch/$arm/artifacts/split-spring/$f" "$out/$arm-$i/$f"
    done
    rm -rf "$scratch/$arm/artifacts/split-spring"
  done
done
python3 -I scripts/measure/split_ab_summary.py "$out" "$rounds"
status=$?
echo "SPLIT-AB verdict exit $status base $base head $head rounds $rounds"
# Packed beside the folder, then moved in: a tar of the folder it writes into reads its own output.
tar -czf "$out.tgz" -C "$out" . && mv "$out.tgz" "$out/report.tgz"
exit $status
