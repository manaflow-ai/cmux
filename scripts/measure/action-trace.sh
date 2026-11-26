#!/usr/bin/env bash
# Fleet entry for action-trace-bench.py: each user action's spans (launch, send to first token, chat switch,
# new chat) against its speed-of-light floor, from the daemon's Chrome trace (CMUX_TRACE_FILE, acpmux
# perf_trace.rs). Leo, 2026-11-25: "we can use the numbers to work on ongoing goals as they are raised and we
# consider what the metaphorical speed of light is against our implementations". Builds a tagged cmux-next
# app at this checkout (bench configuration), runs the bench, and prints the trace between
# ACTION-TRACE-BEGIN/END and one `ACTION-GAP name dur_us floor_us gap_us` line per span:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/action-trace.sh \
#     --ref <sha> --artifact artifacts/action-trace.json [--arg=--burn=16]
# Options: --app=PATH (measure this app, nothing built), --build-at=SHA (build that commit's app with its own
# reload.sh, scripts/measure/app-at-commit.sh), --native-arch, --derived-data=PATH, --config=NAME; the rest go
# to the bench (--burn=N: N busy loops at default priority, the duress run).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/app-at-commit.sh
tag="actiontrace"
out="$(mktemp -d)"
trap 'measure_remove_scratch "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
reload_config=(--config bench) reload_args=() bench_args=() app="" build_at=""
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --app=*) app="${arg#--app=}" ;;
    --build-at=*) build_at="${arg#--build-at=}" ;;
    --native-arch) reload_args+=(--native-arch) ;;
    --derived-data=*) reload_args+=(--derived-data "${arg#--derived-data=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
if [[ -z "$app" ]]; then
  git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
  if [[ -n "$build_at" ]]; then
    app="$(measure_app_at_commit "$build_at" "$tag" "$out/at" "${reload_config[@]}" ${reload_args[@]+"${reload_args[@]}"})"
  else
    CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" "${reload_config[@]}" ${reload_args[@]+"${reload_args[@]}"} 2>&1 | tee "$out/reload.log"
    app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
    if [[ -z "$app" || ! -d "$app" ]]; then
      echo "action-trace: the tagged reload printed no app path" >&2
      grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
      exit 1
    fi
  fi
fi
mkdir -p artifacts
# A fleet step has no LaunchServices session: the bench launches the app binary directly.
CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/action-trace-bench.py --app "$app" \
  --json artifacts/action-trace.json ${bench_args[@]+"${bench_args[@]}"}
