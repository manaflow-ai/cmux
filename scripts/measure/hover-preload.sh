#!/usr/bin/env bash
# Fleet entry for the hover preload bench (plans/cmux-next/hover-preload-DESIGN.md, cmux-ad m34): builds a tagged
# cmux-next DEV app at this checkout, then runs scripts/cmux-next/bench_hover_preload.py:
#   (a) a 120 Hz pointer sweep over the sidebar's workspace rows (200 crossings): wakes started (must be 0),
#       missed refreshes and main-thread busy ms per frame, each pointer move's main-thread ms;
#   (b) time to content after a select, cold and after a 150 ms rest on the row (--trials each);
#   (c) the woken pages hibernate again after the 30 s grace, and the footprint before, woken and after.
# Hover preload is the setting browser.wakeTabsOnHover (off by default, #37124). Every OFF arm launches with the
# setting off and every ON arm with it on. With no base given, OFF and ON are this checkout's app (one build, the
# setting is the only difference): the A/B for hover preload itself. With a base, OFF is the base build with the
# setting off, built first in this checkout so the head build after it reuses the warm DerivedData, and ON is this
# checkout with the setting on: the A/B for a change to the hover path. The base is either
#   --base-revert=<sha>: this checkout with commit <sha> reverted (uncommitted), so OFF and ON differ only in that
#                        change and the setting; or
#   --base-ref=<sha>:    that commit (it must carry this bench's debug socket methods). A base before 1ff2637da6f
#                        (#37124) has no setting: there preload is on whenever browser.keepNeighborTabsAwake > 0; the script warns.
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --measurement --script scripts/measure/hover-preload.sh --ref <sha> \
#     [--arg=--arms=OFF,ON,OFF,ON] [--arg=--base-ref=<sha>] [--arg=--engine=chromium]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# --arms=OFF,ON,OFF,ON (the default) runs the bench once per arm, in that order, on
# this mini: OFF launches the base build (or this one) with the setting off, ON this checkout's with it on.
tag="hoverpre"
out="$(mktemp -d)"
head_sha="$(git rev-parse HEAD)"
# --config=<debug|release|bench> picks reload.sh's build configuration; every other argument goes to the bench.
reload_config=() bench_args=() arms="" base_ref="" base_revert=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --arms=*) arms="${arg#--arms=}" ;;
    --base-ref=*) base_ref="${arg#--base-ref=}" ;;
    --base-revert=*) base_revert="${arg#--base-revert=}" ;;
    # Each arm sets --wake-on-hover itself; the bench takes the last one, so a passed one would make every arm alike.
    --wake-on-hover*) echo "hover-preload: do not pass --wake-on-hover; OFF arms run with it 0, ON arms with it 1" >&2; exit 2 ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
[[ -z "$arms" ]] && arms="OFF,ON,OFF,ON"

# Builds the checked-out commit as tag $1 and prints its app path. A step's checkout has empty submodules: reload.sh
# needs Ghostty's headers and ghostty-next for the bundled cmux-tui.
build() {
  git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$1" ${reload_config[@]+"${reload_config[@]}"} >"$out/reload-$1.log" 2>&1 \
    || { tail -n 40 "$out/reload-$1.log" >&2; grep -E "error:|BUILD FAILED" "$out/reload-$1.log" | head -n 60 >&2 || true; return 1; }
  local app
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload-$1.log" | tail -n 1)"
  if [[ -z "$app" || ! -d "$app" ]]; then
    echo "hover-preload: the tagged reload of $1 printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$out/reload-$1.log" | head -n 60 >&2 || true
    return 1
  fi
  printf '%s\n' "$app"
}

# Warns when the checked-out base (with any uncommitted revert) has no browser.wakeTabsOnHover setting (before
# 1ff2637da6f): there its OFF arm still preloads whenever browser.keepNeighborTabsAwake > 0.
check_base_setting() {
  if ! git grep -q wakeTabsOnHover -- Packages/macOS/CmuxNext/Sources/CmuxNextSettings 2>/dev/null; then
    echo "hover-preload: WARNING: the base ($base_desc) has no browser.wakeTabsOnHover setting (it predates 1ff2637da6f):" \
      "its OFF arm preloads whenever browser.keepNeighborTabsAwake > 0, so OFF vs ON may compare ON with ON" >&2
    base_desc="$base_desc, no wakeTabsOnHover setting"
  fi
}

# Puts the checkout back at the head commit with no local change (after a base build).
restore_head() {
  git reset --quiet --hard "$head_sha"
  git -c advice.detachedHead=false checkout --quiet --detach "$head_sha"
}

base_app="" base_desc=""
if [[ -n "$base_revert" ]]; then
  # A shallow step checkout may lack the commit or its parent; reverting needs both trees.
  depth=()  # --depth only in a checkout that is already shallow, so a full clone stays full
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 2)
  { git cat-file -e "$base_revert^{commit}" && git cat-file -e "$base_revert^^{commit}"; } 2>/dev/null \
    || git fetch --quiet ${depth[@]+"${depth[@]}"} origin "$base_revert" 2>/dev/null || git fetch --quiet ${depth[@]+"${depth[@]}"} https://github.com/manaflow-ai/cmux.git "$base_revert"
  if ! git revert --no-commit "$base_revert" >"$out/revert.log" 2>&1; then
    cat "$out/revert.log" >&2
    echo "hover-preload: $base_revert does not revert cleanly at $head_sha; use --base-ref" >&2
    git revert --abort >/dev/null 2>&1 || true
    restore_head
    exit 1
  fi
  base_desc="head minus $base_revert"
  check_base_setting
  base_app="$(build hoverbase)" || { restore_head; exit 1; }
  restore_head
elif [[ -n "$base_ref" ]]; then
  git cat-file -e "$base_ref^{commit}" 2>/dev/null || git fetch --quiet origin "$base_ref" 2>/dev/null || git fetch --quiet https://github.com/manaflow-ai/cmux.git "$base_ref"
  git -c advice.detachedHead=false checkout --quiet --detach "$base_ref"
  base_desc="base $(git rev-parse HEAD)"
  check_base_setting
  base_app="$(build hoverbase)" || { restore_head; exit 1; }
  restore_head
fi
[[ -n "$base_app" ]] && echo "hover-preload: OFF app built ($base_desc)"
app="$(build "$tag")"
echo "hover-preload: ref $head_sha host $(hostname -s) macOS $(sw_vers -productVersion 2>/dev/null || echo ?)"
# A fleet step has no LaunchServices session: run the app binary itself (bench_memory.launch).
IFS=, read -r -a arm_list <<<"$arms"
index=0 failed=0
for arm in "${arm_list[@]}"; do
  index=$((index + 1))
  label="$(tr '[:upper:]' '[:lower:]' <<<"$arm")"
  arm_app="$app" wake=1 desc="head $head_sha, browser.wakeTabsOnHover on"
  if [[ "$label" == off ]]; then
    # OFF is preload off on whichever build it runs: a base build launched with the setting on would make
    # "base vs ON" an ON vs ON comparison.
    wake=0 desc="head $head_sha, browser.wakeTabsOnHover off"
    if [[ -n "$base_app" ]]; then arm_app="$base_app" desc="$base_desc, browser.wakeTabsOnHover off"; fi
  fi
  echo "hover-preload: arm $index/${#arm_list[@]} $label ($desc)"
  # One arm that fails does not stop the others (each launches its own app); the step fails at the end.
  CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/bench_hover_preload.py --app "$arm_app" --label "$label" \
    --wake-on-hover="$wake" --out "$PWD/hover-preload-$index-$label.json" "$@" || { echo "hover-preload: arm $index ($label) failed" >&2; failed=1; }
done
exit "$failed"
