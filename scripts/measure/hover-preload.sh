#!/usr/bin/env bash
# Fleet entry for the hover preload bench (plans/cmux-next/hover-preload-DESIGN.md, cmux-ad m34): builds a tagged
# cmux-next DEV app at this checkout, then runs scripts/cmux-next/bench_hover_preload.py:
#   (a) a 120 Hz pointer sweep over the sidebar's workspace rows (200 crossings): wakes started (must be 0),
#       missed refreshes and main-thread busy ms per frame, each pointer move's main-thread ms;
#   (b) time to content after a select, cold and after a 150 ms rest on the row (--trials each);
#   (c) the woken pages hibernate again after the 30 s grace, and the footprint before, woken and after.
# OFF is the base build, never a setting (there is no switch that turns hover preload off), built first in this
# checkout so the head build after it reuses the warm DerivedData. ON is this checkout. The base is either
#   --base-revert=<sha>: this checkout with commit <sha> reverted (uncommitted), so OFF and ON differ only in that
#                        change (hover preload landed as a8442a2b089bca34318c6e47b3767cba09f24cb6, #36637); or
#   --base-ref=<sha>:    that commit (it must carry this bench's debug socket methods).
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --measurement --script scripts/measure/hover-preload.sh --ref <sha> \
#     --arg=--base-revert=a8442a2b089bca34318c6e47b3767cba09f24cb6 [--arg=--arms=OFF,ON,OFF,ON] [--arg=--engine=chromium]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# --arms=OFF,ON,OFF,ON (the default with a base; ON alone without) runs the bench once per arm, in that order, on
# this mini: OFF launches the base build, ON this checkout's.
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
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
if [[ -z "$arms" ]]; then
  arms="ON"
  [[ -n "$base_ref$base_revert" ]] && arms="OFF,ON,OFF,ON"
fi
if [[ ",$arms," == *",OFF,"* && -z "$base_ref$base_revert" ]]; then
  echo "hover-preload: an OFF arm needs --base-revert or --base-ref (the base build, not a setting)" >&2
  exit 2
fi

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

# Puts the checkout back at the head commit with no local change (after a base build).
restore_head() {
  git reset --quiet --hard "$head_sha"
  git -c advice.detachedHead=false checkout --quiet --detach "$head_sha"
}

base_app="" base_desc=""
if [[ -n "$base_revert" ]]; then
  # A shallow step checkout may lack the commit or its parent; reverting needs both trees.
  { git cat-file -e "$base_revert^{commit}" && git cat-file -e "$base_revert^^{commit}"; } 2>/dev/null \
    || git fetch --quiet --depth 2 origin "$base_revert"
  if ! git revert --no-commit "$base_revert" >"$out/revert.log" 2>&1; then
    cat "$out/revert.log" >&2
    echo "hover-preload: $base_revert does not revert cleanly at $head_sha; use --base-ref" >&2
    git revert --abort >/dev/null 2>&1 || true
    restore_head
    exit 1
  fi
  base_desc="head minus $base_revert"
  base_app="$(build hoverbase)" || { restore_head; exit 1; }
  restore_head
elif [[ -n "$base_ref" ]]; then
  git cat-file -e "$base_ref^{commit}" 2>/dev/null || git fetch --quiet origin "$base_ref"
  git -c advice.detachedHead=false checkout --quiet --detach "$base_ref"
  base_desc="base $(git rev-parse HEAD)"
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
  arm_app="$app"
  [[ "$label" == off ]] && arm_app="$base_app"
  echo "hover-preload: arm $index/${#arm_list[@]} $label ($([[ "$label" == off ]] && echo "$base_desc" || echo "head $head_sha"))"
  # One arm that fails does not stop the others (each launches its own app); the step fails at the end.
  CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/bench_hover_preload.py --app "$arm_app" --label "$label" \
    --out "$PWD/hover-preload-$index-$label.json" "$@" || { echo "hover-preload: arm $index ($label) failed" >&2; failed=1; }
done
exit "$failed"
