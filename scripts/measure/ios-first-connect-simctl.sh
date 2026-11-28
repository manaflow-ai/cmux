#!/usr/bin/env bash
# First connect on iOS without XCUITest: the app LaunchTTIUITests just built, launched warm with `simctl launch` on
# a simulator of its own, with the same mock Mac and list rig (CMUX_MOBILE_MOCK_AUTH, 150 seeded workspaces, the
# same launch arguments as LaunchTTIUITests.makeApp). Each launch's marks come from the app's own log (LaunchMarks
# logs `timing launch <mark> (<ms>ms)` in every build, ms since the kernel's process start, so dyld counts), read
# with `log stream` on the simulator. It prints one `SIMCTL_FIRSTCONNECT {json}` line: per mark (main,
# did_finish_launching, first_frame, workspaces_list_frame) the samples and p50/p90 (nearest rank). It also saves the
# screen after the first (cold) and last (warm) launch, simctl-launch-cold.png and simctl-launch-warm.png, so a
# before/after run is a visual diff of launch as well as a timing one.
#
# Why: under XCUITest the warm list_ms is ~4.9 s p50 while the app's pre-main is <1 s, so the probe's
# first_connect may measure XCUITest's relaunch more than the app. This arm measures the same app, same build, same
# rig, launched the way a person's tap launches it.
#
#   (ios-launch-tti-hosted.yml runs it in each leg after LaunchTTIUITests)
# Time zero: each mark is ms since the kernel's start of the app's process, so `simctl launch`'s own work before
# the spawn is not in it. To show that, each launch also records the host clock just before `simctl launch` (t0)
# and when it returns (t1); the `spawn` block gives process start minus t0 (simctl's cost before the process
# exists) and t1 minus process start, from the `main` event's log timestamp minus its ms.
#
# --tag NAME names the arm (default simctl): its files are simctl-first-connect[-NAME].json and its line
# SIMCTL_FIRSTCONNECT {"arm": NAME, ...}. The launch floor (scripts/measure/ios-launch-floor) runs as --tag floor.
#
#   bash scripts/measure/ios-first-connect-simctl.sh [--app PATH] [--runs 20] [--out artifacts/ios-sim] [--tag NAME]
set -euo pipefail

runs=20
out=artifacts/ios-sim
app=""
tag=simctl
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --runs) runs="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --tag) tag="$2"; shift 2 ;;
    *) echo "ios-first-connect-simctl.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$app" ]]; then
  # LaunchTTIUITests' own build (dd-ui, the Demo config the timing suites use), else the step's Demo build.
  for c in .build/ios-sim/dd-ui/Build/Products/*-iphonesimulator/CmuxMobileApp.app \
           .build/ios-sim/dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app; do
    [[ -d "$c" ]] && { app="$c"; break; }
  done
fi
[[ -n "$app" && -d "$app" ]] || { echo "ios-first-connect-simctl.sh: no built CmuxMobileApp.app" >&2; exit 3; }
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
mkdir -p "$out"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/fc-simctl.XXXXXX")"
set_dir="$work/sims"
mkdir -p "$set_dir"
sim() { xcrun simctl --set "$set_dir" "$@"; }
stream_pid=""
cleanup() {
  [[ -n "$stream_pid" ]] && kill "$stream_pid" 2>/dev/null || true
  sim shutdown all >/dev/null 2>&1 || true
  sim delete all >/dev/null 2>&1 || true
}
trap cleanup EXIT

read -r runtime device_type device_name <<<"$(xcrun simctl list -j runtimes devicetypes |
  python3 -I scripts/ci/ios_sim_runtime.py --with-name)"
udid="$(sim create fc-simctl "$device_type" "$runtime")"
sim boot "$udid"
sim bootstatus "$udid" -b >/dev/null
sim install "$udid" "$app"
echo "ios-first-connect-simctl: $device_name, $runtime, $bundle from $app"

stream="$work/stream.ndjson"
sim spawn "$udid" log stream --level info --style ndjson \
  --predicate 'subsystem == "dev.cmux.mobile" AND category == "timing" AND eventMessage BEGINSWITH "timing launch "' \
  >"$stream" 2>"$work/stream.err" &
stream_pid=$!
sleep 2

export SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 SIMCTL_CHILD_CMUX_MOBILE_LAUNCH_MARKS=1 \
  SIMCTL_CHILD_CMUX_MOBILE_LIST_SCREEN=workspaces SIMCTL_CHILD_CMUX_MOBILE_LIST_COUNT=150 \
  SIMCTL_CHILD_CMUX_MOBILE_LIST_PASSES=0
args=(-cmuxMobile.setupComplete YES -cmux-mobile-tab workspaces -cmux-mobile-no-restore -cmux-mobile-term-no-intro)

pids="$work/pids.txt"
: >"$pids"
# Run 0 is unmeasured (the app's caches and the OS's warm, as LaunchTTIUITests' first launch).
for i in $(seq 0 "$runs"); do
  sim terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  sleep 1
  t0="$(python3 -c 'import time; print(f"{time.time():.6f}")')"
  line="$(sim launch "$udid" "$bundle" "${args[@]}")"
  t1="$(python3 -c 'import time; print(f"{time.time():.6f}")')"
  pid="${line##*: }"
  echo "$i $pid $t0 $t1" >>"$pids"
  # Bounded: the list's frame mark for this pid, else 30 s.
  for _ in $(seq 1 300); do
    grep workspaces_list_frame "$stream" 2>/dev/null | grep -Eq "\"processID\" *: *$pid[,} ]" && break
    sleep 0.1
  done
  # The frame a person sees: run 0 is the first launch after install (cold), the last run is warm. One
  # second past the list's frame mark so the list has drawn, never timed (the marks above are the timing).
  if [[ "$i" -eq 0 || "$i" -eq "$runs" ]]; then
    sleep 1
    shot="$out/simctl-launch-$([[ "$i" -eq 0 ]] && echo cold || echo warm).png"
    sim io "$udid" screenshot "$shot" >/dev/null 2>&1 && echo "ios-first-connect-simctl: screenshot $shot" ||
      echo "ios-first-connect-simctl: screenshot failed for run $i" >&2
  fi
done
sleep 1
kill "$stream_pid" 2>/dev/null || true
stream_pid=""
suffix=""
[[ "$tag" != simctl ]] && suffix="-$tag"
cp "$stream" "$out/simctl-launch-marks$suffix.ndjson"
cp "$pids" "$out/simctl-launch-pids$suffix.txt"

python3 -I - "$stream" "$pids" "$out/simctl-first-connect$suffix.json" "$bundle" "$device_name" "$runtime" "$tag" <<'PY'
import datetime, json, math, re, sys
stream, pids_path, dest, bundle, device, runtime, tag = sys.argv[1:]
pid_run = {}
host = {}
for l in open(pids_path):
    f = l.split()
    if len(f) >= 2 and f[1].isdigit():
        pid_run[int(f[1])] = int(f[0])
        if len(f) >= 4:
            host[int(f[0])] = (float(f[2]), float(f[3]))
def when(ts):
    # log stream ndjson: "2026-11-28 12:00:00.123456-0800"
    try:
        return datetime.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    except (TypeError, ValueError):
        return None
start = {}
marks = {}
pat = re.compile(r"timing launch (\w+) \((\d+)ms\)")
for l in open(stream):
    try:
        ev = json.loads(l)
    except ValueError:
        continue
    m = pat.search(ev.get("eventMessage", ""))
    run = pid_run.get(ev.get("processID"))
    if m and run is not None and run > 0:
        marks.setdefault(run, {}).setdefault(m.group(1), int(m.group(2)))
        t = when(ev.get("timestamp"))
        if t is not None and run not in start:
            start[run] = t - int(m.group(2)) / 1000
def rank(s, p):
    s = sorted(s)
    return s[max(0, math.ceil(p / 100 * len(s)) - 1)] if s else None
lead = [round((start[r] - host[r][0]) * 1000) for r in sorted(start) if r in host]
ret = [round((host[r][1] - start[r]) * 1000) for r in sorted(start) if r in host]
out = {"arm": tag, "bundle": bundle, "device": device, "runtime": runtime, "launches": len(pid_run) - 1,
       "with_list_frame": sum(1 for r in marks.values() if "workspaces_list_frame" in r),
       "spawn": {"process_start_minus_simctl_call_ms": {"p50": rank(lead, 50), "p90": rank(lead, 90), "samples": lead},
                 "simctl_return_minus_process_start_ms": {"p50": rank(ret, 50), "p90": rank(ret, 90), "samples": ret}},
       "marks": {}}
for name in ("main", "app_init_done", "did_finish_launching", "first_frame", "shell_frame", "workspaces_list_frame"):
    s = [r[name] for _, r in sorted(marks.items()) if name in r]
    out["marks"][name] = {"n": len(s), "p50_ms": rank(s, 50), "p90_ms": rank(s, 90), "samples_ms": s}
open(dest, "w").write(json.dumps(out, indent=1) + "\n")
print("SIMCTL_FIRSTCONNECT " + json.dumps(out))
PY
