#!/usr/bin/env bash
# What the cmux iOS app does before main, on the simulator the launch TTI harness used: the app the UI
# tests launched (Demo, from the harness's build-for-testing), read three ways.
#   1. The image: its dylibs (otool -L), embedded frameworks, and each image's static initializers
#      (__mod_init_func / __init_offsets entries), and what the UI tests' .xctestrun inserts into it
#      (DYLD_INSERT_LIBRARIES: the Main Thread Checker and the like).
#   2. Warm launches by simctl, outside XCTest: the app's own pre_main_init / pre_main_cpu (LaunchMarks,
#      logged as "timing launch pre_main_init"), N plain and N with what the .xctestrun inserts, so
#      the difference is the test harness's, not the app's.
#   3. One launch with dyld's DYLD_PRINT_LIBRARIES / DYLD_PRINT_INITIALIZERS: what loads and runs.
# Diagnostic only: every failure is noted, none fails the job.
#
# usage: ios-launch-premain.sh OUT_JSON [SUMMARY_MD]
# CMUX_PREMAIN_RUNS: launches per arm (default 8), after one unmeasured launch.
set -uo pipefail
out_json="$1"
summary_md="${2:-}"
runs="${CMUX_PREMAIN_RUNS:-8}"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ios-launch-premain.XXXXXX")"
udid="" logger=""
cleanup() {
  [[ -z "$logger" ]] || kill "$logger" >/dev/null 2>&1 || true
  if [[ -n "$udid" ]]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

root="${CMUX_DERIVED_DATA_SLOT:-.build/ios-sim}"
app="$(find "$root" .build/ios-sim -maxdepth 6 -type d -path '*/Demo-iphonesimulator/CmuxMobileApp.app' 2>/dev/null | head -n 1)"
xctestrun="$(find "$root" .build/ios-sim -maxdepth 5 -name '*iphonesimulator*.xctestrun' 2>/dev/null | head -n 1)"
if [[ -z "$app" ]]; then
  echo "ios-launch-premain: no Demo-iphonesimulator/CmuxMobileApp.app under $root" >&2
  echo '{"error":"no app"}' >"$out_json"
  exit 0
fi
echo "ios-launch-premain: $app"
bin="$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"

# 1. The image.
otool -L "$bin" >"$work/otool-L.txt" 2>&1 || true
inits() { # static initializer entries in one Mach-O
  otool -l "$1" 2>/dev/null | awk '/sectname __mod_init_func|sectname __init_offsets/{f=$2; getline; getline; getline; print f, $2}' |
    python3 -c 'import sys
n=0
for l in sys.stdin:
    k,s=l.split(); s=int(s,16); n+=s//(8 if k=="__mod_init_func" else 4)
print(n)'
}
: >"$work/images.tsv"
for m in "$bin" "$app"/Frameworks/*.framework/* "$app"/Frameworks/*.dylib; do
  [[ -f "$m" ]] && file "$m" | grep -q 'Mach-O' || continue
  printf '%s\t%s\t%s\n' "${m#"$app"/}" "$(stat -f %z "$m")" "$(inits "$m")" >>"$work/images.tsv"
done
inserted=""
if [[ -n "$xctestrun" ]]; then
  inserted="$(plutil -convert json -o - "$xctestrun" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
out = set()
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ("EnvironmentVariables", "UITargetAppEnvironmentVariables", "TestingEnvironmentVariables") and isinstance(v, dict):
                for ek, ev in v.items():
                    if ek == "DYLD_INSERT_LIBRARIES" and ev: out.add(ev)
            walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(d)
print(":".join(sorted(out)))' 2>/dev/null || true)"
  plutil -convert json -o - "$xctestrun" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
def walk(o, p=""):
    if isinstance(o, dict):
        for k, v in o.items():
            if "Environment" in k and isinstance(v, dict): print(p + "/" + k, sorted(v))
            walk(v, p + "/" + k)
    elif isinstance(o, list):
        for i, v in enumerate(o): walk(v, p + f"[{i}]")
walk(d)' >"$work/xctestrun-env.txt" 2>&1 || true
fi
# The .xctestrun names it with __PLATFORMS__-style placeholders: resolve against this Xcode.
dev="$(xcode-select -p)"
inserted="${inserted//__PLATFORMS__/$dev/Platforms}"
inserted="${inserted//__TESTROOT__/$(dirname "${xctestrun:-.}")}"
inserted="${inserted//__SHAREDFRAMEWORKS__/$dev/../SharedFrameworks}"
mtc="$(find "$dev" -name libMainThreadChecker.dylib -path '*iPhoneSimulator*' 2>/dev/null | head -n 1)"
[[ -n "$mtc" ]] || mtc="$(find "$dev" -name libMainThreadChecker.dylib 2>/dev/null | head -n 1)"
echo "ios-launch-premain: .xctestrun inserts: ${inserted:-none}; Main Thread Checker: ${mtc:-not found}"

# The harness's iPhone type and runtime (its SUMMARY.md), as the floor step reads them.
device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" runtime=""
if [[ -n "$summary_md" && -f "$summary_md" ]]; then
  line="$(grep -m1 -E '^- simulator: [^,]+ on [^ ]+$' "$summary_md" || true)"
  if [[ -n "$line" ]]; then
    line="${line#- simulator: }"
    device_type="com.apple.CoreSimulator.SimDeviceType.${line%% on *}"
    runtime="com.apple.CoreSimulator.SimRuntime.${line##* on }"
  fi
fi
[[ -n "$runtime" ]] || runtime="$(xcrun simctl list -j runtimes | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
print(sorted(rts, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])')"

udid="$(xcrun simctl create "ios-launch-premain-${GITHUB_RUN_ID:-local}" "$device_type" "$runtime")"
xcrun simctl boot "$udid" && xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
xcrun simctl spawn "$udid" log stream --level info --style ndjson \
  --predicate 'subsystem == "dev.cmux.mobile" AND category == "timing"' >"$work/timing.ndjson" 2>/dev/null &
logger=$!
sleep 2

# 2. One launch: the app's pre-main line from the log (bounded 30 s), as "arm wall cpu pageins".
launch() { # ARM [extra simctl env...]
  local arm="$1" before i line; shift
  before="$(grep -c 'timing launch pre_main_init' "$work/timing.ndjson" 2>/dev/null || true)"
  env "$@" SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 \
    xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" >/dev/null 2>&1 || return 1
  for ((i = 0; i < 300; i++)); do
    line="$(grep 'timing launch pre_main_init' "$work/timing.ndjson" 2>/dev/null | sed -n "$((before + 1))p")"
    if [[ -n "$line" ]]; then
      python3 -c '
import json, re, sys
m = re.search(r"pre_main_init \((\d+)ms, cpu (\d+)ms, pageins (\d+)\)", json.loads(sys.argv[2])["eventMessage"])
print(json.dumps({"arm": sys.argv[1], "wall": int(m[1]), "cpu": int(m[2]), "pageins": int(m[3])}))' "$arm" "$line"
      return 0
    fi
    sleep 0.1
  done
  echo "ios-launch-premain: $arm launch logged no pre-main line in 30 s" >&2
  return 1
}
: >"$work/samples.jsonl"
launch warmup >/dev/null || true
sleep 3
for ((n = 1; n <= runs; n++)); do
  launch plain >>"$work/samples.jsonl" || true
  sleep 3
  if [[ -n "$inserted" ]]; then launch xctestrun_inserts SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$inserted" >>"$work/samples.jsonl" || true; sleep 3; fi
  if [[ -n "$mtc" && "$inserted" != *libMainThreadChecker* ]]; then
    launch main_thread_checker SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$mtc" >>"$work/samples.jsonl" || true; sleep 3
  fi
done

# 3. dyld's own account of one launch.
xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
SIMCTL_CHILD_DYLD_PRINT_LIBRARIES=1 SIMCTL_CHILD_DYLD_PRINT_INITIALIZERS=1 SIMCTL_CHILD_CMUX_MOBILE_MOCK_AUTH=1 \
  xcrun simctl launch --stderr="$work/dyld.txt" --stdout=/dev/null "$udid" "$bundle_id" >/dev/null 2>&1 || true
sleep 8
xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true

python3 - "$work" "$out_json" "$app" "${inserted:-}" "${mtc:-}" <<'PY'
import collections, json, math, pathlib, re, sys
work, out_json, app, inserted, mtc = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
rows = [json.loads(l) for l in (work / "samples.jsonl").read_text().splitlines() if l.strip()]
def q(xs, p):
    s = sorted(xs)
    return s[max(0, math.ceil(p / 100 * len(s)) - 1)] if s else None
arms = {}
for arm in sorted({r["arm"] for r in rows}):
    rs = [r for r in rows if r["arm"] == arm]
    arms[arm] = {k: {"samples": [r[k] for r in rs], "p50": q([r[k] for r in rs], 50), "p90": q([r[k] for r in rs], 90)}
                 for k in ("wall", "cpu", "pageins")}
otool = (work / "otool-L.txt").read_text().splitlines()[1:]
linked = [l.strip().split(" (")[0] for l in otool if l.strip()]
own = [l for l in linked if l.startswith("@rpath") or l.startswith("@executable_path")]
images = []
for l in (work / "images.tsv").read_text().splitlines():
    name, size, n = l.split("\t")
    images.append({"image": name, "bytes": int(size), "static_initializers": int(n or 0)})
dyld = (work / "dyld.txt").read_text(errors="replace").splitlines() if (work / "dyld.txt").exists() else []
loads = [l for l in dyld if "dyld" in l and ("<" in l or "load" in l.lower()) and "initializer" not in l.lower()]
inits = [l for l in dyld if "initializer" in l.lower()]
per_image = collections.Counter()
for l in inits:
    m = re.search(r"/([^/]+?)(?:\.framework/[^ ]*|\.dylib)?(?:\s|$)", l.split("initializer")[-1]) or re.search(r"/([^/ ]+)\s*$", l)
    per_image[m[1] if m else l[-60:]] += 1
out = {"app": app, "dyld_insert_libraries_from_xctestrun": inserted, "main_thread_checker": mtc, "arms": arms,
       "linked_dylibs": len(linked), "linked_own_dylibs": own, "images": images,
       "dyld_print": {"lines": len(dyld), "library_lines": len(loads), "initializer_lines": len(inits),
                      "initializers_by_image_top": per_image.most_common(25), "head": dyld[:40]},
       "xctestrun_env": (work / "xctestrun-env.txt").read_text() if (work / "xctestrun-env.txt").exists() else ""}
pathlib.Path(out_json).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(out_json).write_text(json.dumps(out, indent=1) + "\n")
print("PREMAIN " + json.dumps({k: out[k] for k in ("arms", "linked_dylibs", "linked_own_dylibs", "images")}))
print("PREMAIN dyld lines", len(dyld), "initializers", len(inits), per_image.most_common(15))
print("PREMAIN xctestrun inserts", inserted or "none")
print(out["xctestrun_env"])
PY
exit 0
