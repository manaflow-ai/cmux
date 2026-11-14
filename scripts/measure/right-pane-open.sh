#!/usr/bin/env bash
# Fleet entry for right-pane-open-bench.py: click to first content for every right-side open of a cmux NEXT
# chat (the header's Terminal, Browser, Changes, Files and New tab, a subagent line, New side chat), light,
# under STRESS and right after a restart (Leo, 2026-11-05: "Those need to be fast. There's no reason for them
# to have a delay, even under load."). Builds a tagged cmux-next app at this checkout (bench configuration:
# Release optimization with the debug.* control methods kept), then runs the bench. Runs alone on the worker
# because it launches an app and loads every core:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/right-pane-open.sh \
#     --ref <sha> --artifact artifacts/right-pane-open.json [--arg=--runs=8]
# A before/after pair on one worker: --pair=BEFORE_SHA,AFTER_SHA builds an app at each commit (a detached
# worktree of each, this checkout's bench for both), then runs the bench on before and after in turn; the JSON is
# {"pair": {...}, "before": <report>, "after": <report>}, and the log prints each arm's table.
# Build options (the rest go to the bench): --app=PATH, --skip-build, --native-arch, --universal,
# --derived-data=PATH, --config=NAME, as scripts/measure/chat-open.sh takes them. The bench puts the app on a
# 1920 x 1200 virtual display (--vdisplay=HZ, 0 for the host's display), which STRESS's window needs.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
root="$(pwd)"
tag="rpopen"
out="$(mktemp -d)"
reload_config=(--config bench) reload_args=() bench_args=() app="" skip_build=0 pair=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --app=*) app="${arg#--app=}" ;;
    --skip-build) skip_build=1 ;;
    --native-arch) reload_args+=(--native-arch) ;;
    --universal) export CMUX_RELOAD_NATIVE_ARCH=0 ;;
    --derived-data=*) reload_args+=(--derived-data "${arg#--derived-data=}") ;;
    --pair=*) pair="${arg#--pair=}" ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}

# Builds a tagged app in checkout $1 with tag $2 and prints its path (the reload's log goes to stderr).
build_app() {
  local checkout="$1" build_tag="$2" log="$out/reload-$2.log" built
  # A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
  # from the pinned cache) and ghostty-next for the bundled cmux-tui.
  git -C "$checkout" submodule update --init --depth 1 ghostty ghostty-next >/dev/null
  (cd "$checkout" && CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$build_tag" "${reload_config[@]}" \
    ${reload_args[@]+"${reload_args[@]}"}) >"$log" 2>&1 || true
  cat "$log" >&2
  built="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$log" | tail -n 1)"
  if [[ -z "$built" || ! -d "$built" ]]; then
    echo "right-pane-open: the tagged reload in $checkout printed no app path" >&2
    grep -E "error:|BUILD FAILED" "$log" | head -n 60 >&2 || true
    return 1
  fi
  printf '%s\n' "$built"
}

mkdir -p artifacts
if [[ -n "$pair" ]]; then
  before_sha="${pair%%,*}" after_sha="${pair#*,}"
  for sha in "$before_sha" "$after_sha"; do
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "right-pane-open: --pair takes two full commit SHAs, BEFORE,AFTER (got '$pair')" >&2
      exit 2
    fi
    git cat-file -e "$sha^{commit}" 2>/dev/null || git fetch --quiet origin "$sha" 2>/dev/null || git fetch --quiet https://github.com/manaflow-ai/cmux.git "$sha"
  done
  # Worktrees of this attempt only, removed on exit by path (never by name or glob).
  trap 'git -C "$root" worktree remove --force "$out/before" 2>/dev/null || true; git -C "$root" worktree remove --force "$out/after" 2>/dev/null || true' EXIT
  git worktree add --detach "$out/before" "$before_sha" >/dev/null
  git worktree add --detach "$out/after" "$after_sha" >/dev/null
  before_app="$(build_app "$out/before" "${tag}a")"
  after_app="$(build_app "$out/after" "${tag}b")"
  status=0
  for arm in before after; do
    arm_app="$before_app"
    [[ "$arm" == before ]] || arm_app="$after_app"
    echo "right-pane-open: PAIR $arm $([[ "$arm" == before ]] && echo "$before_sha" || echo "$after_sha") app $arm_app"
    # This checkout's bench for both arms, so the pair differs only in the app.
    CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/right-pane-open-bench.py --app "$arm_app" --tag "${tag}${arm:0:1}" \
      --json "artifacts/right-pane-open-$arm.json" --md "artifacts/right-pane-open-$arm.md" "$@" || status=1
  done
  python3 - "$before_sha" "$after_sha" "$(git rev-parse HEAD)" <<'PY'
import json, os, sys
before, after, bench = sys.argv[1:4]
report = {"pair": {"before": before, "after": after, "bench": bench}}
for arm in ("before", "after"):
    path = f"artifacts/right-pane-open-{arm}.json"
    report[arm] = json.load(open(path)) if os.path.exists(path) else None
json.dump(report, open("artifacts/right-pane-open.json", "w"), indent=1)
PY
  exit "$status"
fi

# The commit, configuration and architecture an app was built for: --skip-build reuses only a match.
build_id="$(git rev-parse HEAD)/${reload_config[1]}/${CMUX_RELOAD_NATIVE_ARCH:-default}/${reload_args[*]:-}"
build_id="${build_id// /,}"
# What the last build left: its commit and its app, so --skip-build reuses only an app of this commit.
last_build=".build/right-pane-open-last-build"
if [[ -z "$app" && "$skip_build" -eq 1 && -f "$last_build" ]]; then
  read -r built_at built_app <"$last_build" || true
  if [[ "${built_at:-}" == "$build_id" && -d "${built_app:-}" ]]; then
    app="$built_app"
    echo "right-pane-open: --skip-build: the app built as $build_id"
  else
    echo "right-pane-open: --skip-build: no app built as $build_id here (last: ${built_at:-none}); building"
  fi
elif [[ -z "$app" && "$skip_build" -eq 1 ]]; then
  echo "right-pane-open: --skip-build: no earlier build in this checkout; building"
fi
if [[ -n "$app" ]]; then
  if [[ ! -d "$app" ]]; then
    echo "right-pane-open: --app $app is not an app bundle" >&2
    exit 1
  fi
else
  app="$(build_app "$root" "$tag")"
  mkdir -p .build
  printf '%s %s\n' "$build_id" "$app" >"$last_build"
fi
# A fleet step has no LaunchServices session: the bench launches the app binary directly.
CMUX_BENCH_LAUNCH=direct exec python3 scripts/cmux-next/right-pane-open-bench.py --app "$app" \
  --json artifacts/right-pane-open.json --md artifacts/right-pane-open.md "$@"
