#!/usr/bin/env bash
# Fleet entry for the main thread under load (plans/cmux-next/main-thread-scheduling.md 1.5, step 0): builds a tagged
# cmux-next app at this checkout (bench configuration: Release optimization with the debug.* control methods kept),
# then, on the LARGE session (scripts/cmux-next/perf-stress-session.py `build_large`: 60 workspaces x 6 tabs, 5 title
# streams and 5 agent statuses a second in hidden workspaces), types real keys into a `cat` terminal of the shown
# workspace. It launches and activates an app and posts HID keys, so it runs alone on a mini with a console and the
# input grant. Never on a person's Mac.
#   cmux-ci run --class exclusive --measurement --label measure --key mts-<step> --ref <sha> \
#     --script scripts/measure/main-thread-large-session.sh --artifact artifacts/main-thread/report.json \
#     --arg=--config=bench --arg=--mode=test
#   ... --arg=--config=bench --arg=--mode=bench --arg=--session=light,large
# --mode=test (default): tests/test_cmux_next_main_thread_large_session.py, the step's red-first regression test: exit 1
#   on a main-thread task over 8 ms or a missed refresh while typing, with the owner and stack of each; report.json is
#   the bench's report of the run.
# --mode=bench: sidebar-churn-typing.py per session of --session (light: 1 workspace and the typing one, the sidebar
#   churn at 10 Hz; large: the LARGE session and its agent load), no pass or fail; report.json holds each session's
#   report and the host, macOS and refresh rate. Before/after rows: run it at both commits, interleaved (bench_arms.py).
# Build options: --config=NAME (reload.sh's configuration, default bench), --app=PATH (measure this app, build nothing).
# Every other argument goes to the test (--mode=test) or to each bench run (--mode=bench), e.g. --samples=120 --trace.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="mtslarge"
out="$(pwd)/artifacts/main-thread"
mkdir -p "$out"
reload_config=(--config bench) mode="test" sessions="light,large" app="" rest=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --mode=*) mode="${arg#--mode=}" ;;
    --session=*) sessions="${arg#--session=}" ;;
    --app=*) app="${arg#--app=}" ;;
    *) rest+=("$arg") ;;
  esac
done
case "$mode" in
  test | bench) ;;
  *) echo "main-thread-large-session: --mode is test or bench, not $mode" >&2; exit 2 ;;
esac
if [[ -z "$app" ]]; then
  # A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes from the pinned
  # cache) and ghostty-next for the bundled cmux-tui.
  git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" "${reload_config[@]}" 2>&1 | tee "$out/reload.log"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
fi
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "main-thread-large-session: no app to measure (the tagged reload printed no app path)" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" 2>/dev/null | head -n 60 >&2 || true
  exit 1
fi
# A fleet step has no LaunchServices session: the bench launches the app binary directly.
export CMUX_BENCH_LAUNCH=direct
if [[ "$mode" == "test" ]]; then
  status=0
  python3 tests/test_cmux_next_main_thread_large_session.py --app "$app" --tag "$tag" --out "$out" \
    ${rest[@]+"${rest[@]}"} || status=$?
  [[ -f "$out/large-report.json" ]] && cp "$out/large-report.json" "$out/report.json"
  exit "$status"
fi
reports=()
IFS=',' read -r -a session_list <<<"$sessions"
for session in "${session_list[@]}"; do
  case "$session" in
    light) extra=(--session light --workspaces 1 --groups 1) ;;
    large) extra=(--session large) ;;
    *) echo "main-thread-large-session: unknown session $session (light, large)" >&2; exit 2 ;;
  esac
  mkdir -p "$out/$session"
  python3 scripts/cmux-next/sidebar-churn-typing.py --app "$app" --tag "$tag-$session" --out "$out/$session" \
    --json "$out/$session/report.json" --input real "${extra[@]}" ${rest[@]+"${rest[@]}"} || true
  reports+=("$session=$out/$session/report.json")
done
python3 - "$out/report.json" "${reports[@]}" <<'PY'
import json, os, platform, subprocess, sys
merged = {"host": os.uname().nodename, "macos": platform.mac_ver()[0], "sessions": {}}
for item in sys.argv[2:]:
    session, path = item.split("=", 1)
    try:
        with open(path) as handle:
            report = json.load(handle)
    except (OSError, ValueError) as error:
        report = {"error": str(error)}
    merged["sessions"][session] = report
    refresh = next((p.get("frames", {}).get("refresh_ms") for p in report.get("phases") or [] if isinstance(p.get("frames"), dict)), None)
    if refresh:
        merged.setdefault("refresh_hz", {})[session] = round(1000 / refresh, 1)
with open(sys.argv[1], "w") as handle:
    json.dump(merged, handle, indent=1)
print("main-thread-large-session: " + json.dumps({"host": merged["host"], "macos": merged["macos"], "refresh_hz": merged.get("refresh_hz")}))
PY
