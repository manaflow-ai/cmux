#!/usr/bin/env bash
# Fleet entry for the hover preload bench (plans/cmux-next/hover-preload-DESIGN.md, cmux-ad m34): builds a tagged
# cmux-next DEV app at this checkout, then runs scripts/cmux-next/bench_hover_preload.py:
#   (a) a 120 Hz pointer sweep over the sidebar's workspace rows (200 crossings): wakes started (must be 0),
#       missed refreshes and main-thread busy ms per frame, each pointer move's main-thread ms;
#   (b) time to content after a select, cold and after a 150 ms rest on the row (--trials each);
#   (c) the woken pages hibernate again after the 30 s grace, and the footprint before, woken and after.
# OFF is the base build: --base-ref=<sha> builds that commit first (it must carry this bench's harness: the base
# commit with the harness commit cherry-picked, pushed to manaflow-ai/cmux), in this checkout, so the head build after
# it reuses the warm DerivedData; there is no setting that turns hover preload off. ON is this checkout.
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/hover-preload.sh --ref <sha> \
#     --arg=--base-ref=<base sha> [--arg=--arms=OFF,ON,OFF,ON] [--arg=--engine=chromium]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# --arms=OFF,ON,OFF,ON (the default with --base-ref; ON alone without) runs the bench once per arm, in that order, on
# this mini: OFF launches the base build, ON this checkout's.
tag="hoverpre"
out="$(mktemp -d)"
head_sha="$(git rev-parse HEAD)"
# --config=<debug|release|bench> picks reload.sh's build configuration; every other argument goes to the bench.
reload_config=() bench_args=() arms="" base_ref=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --arms=*) arms="${arg#--arms=}" ;;
    --base-ref=*) base_ref="${arg#--base-ref=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
if [[ -z "$arms" ]]; then
  arms="ON"
  [[ -n "$base_ref" ]] && arms="OFF,ON,OFF,ON"
fi
if [[ ",$arms," == *",OFF,"* && -z "$base_ref" ]]; then
  echo "hover-preload: an OFF arm needs --base-ref (the base build, not a setting)" >&2
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

base_app=""
if [[ -n "$base_ref" ]]; then
  git cat-file -e "$base_ref^{commit}" 2>/dev/null || git fetch --quiet origin "$base_ref"
  git -c advice.detachedHead=false checkout --quiet --detach "$base_ref"
  base_app="$(build hoverbase)" || { git checkout --quiet --detach "$head_sha"; exit 1; }
  echo "hover-preload: base $(git rev-parse HEAD) app built"
  git -c advice.detachedHead=false checkout --quiet --detach "$head_sha"
fi
app="$(build "$tag")"
echo "hover-preload: ref $head_sha"
# A fleet step has no LaunchServices session: run the app binary itself (bench_memory.launch).
IFS=, read -r -a arm_list <<<"$arms"
index=0 failed=0
for arm in "${arm_list[@]}"; do
  index=$((index + 1))
  label="$(tr '[:upper:]' '[:lower:]' <<<"$arm")"
  arm_app="$app"
  [[ "$label" == off ]] && arm_app="$base_app"
  echo "hover-preload: arm $index/${#arm_list[@]} $label ($([[ "$label" == off ]] && echo "base $base_ref" || echo "head $head_sha"))"
  # One arm that fails does not stop the others (each launches its own app); the step fails at the end.
  CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/bench_hover_preload.py --app "$arm_app" --label "$label" \
    --out "$PWD/hover-preload-$index-$label.json" "$@" || { echo "hover-preload: arm $index ($label) failed" >&2; failed=1; }
done
exit "$failed"
