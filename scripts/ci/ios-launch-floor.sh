#!/usr/bin/env bash
# The launch floor of an iOS simulator: a minimal SwiftUI app (no frameworks beyond SwiftUI's own,
# no SwiftPM packages), launched warm on the iPhone type and runtime the launch TTI harness used,
# timed with the same process-start clock as the real app's LaunchMarks (kinfo_proc p_starttime).
# What the real app's list_ms and pre_main_init take above these numbers is ours; the rest is the
# runner and the simulator.
#
# usage: ios-launch-floor.sh OUT_JSON [SUMMARY_MD]
#   OUT_JSON   samples and p50/p90 of main_ms (App.init) and first_frame_ms (first presented frame)
#   SUMMARY_MD the harness's SUMMARY.md, read for its "- simulator: TYPE on RUNTIME" line
# CMUX_LAUNCH_FLOOR_RUNS: measured warm launches (default 20), after one unmeasured launch.
# CMUX_LAUNCH_FLOOR_LINK_LIKE: a Mach-O (the real app's binary). The floor app then also links every
#   system framework and /usr/lib dylib that binary links (otool -L; @rpath ones skipped), so the
#   floor-vs-linked difference is what the app's link list alone costs before main.
# CMUX_LAUNCH_FLOOR_EACH=1 (with LINK_LIKE): instead, one floor per linked dylib, each linking only
#   that one, launched round-robin with the plain floor; OUT_JSON ranks each dylib's margin before main.
set -euo pipefail
out_json="$1"
summary_md="${2:-}"
runs="${CMUX_LAUNCH_FLOOR_RUNS:-20}"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ios-launch-floor.XXXXXX")"
udid=""
cleanup() {
  if [[ -n "$udid" ]]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# The harness's iPhone type and runtime, else the newest iOS runtime's first iPhone.
device_type="" runtime=""
if [[ -n "$summary_md" && -f "$summary_md" ]]; then
  line="$(grep -m1 -E '^- simulator: [^,]+ on [^ ]+$' "$summary_md" || true)"
  if [[ -n "$line" ]]; then
    line="${line#- simulator: }"
    device_type="com.apple.CoreSimulator.SimDeviceType.${line%% on *}"
    runtime="com.apple.CoreSimulator.SimRuntime.${line##* on }"
  fi
fi
if [[ -z "$runtime" ]]; then
  read -r runtime device_type < <(xcrun simctl list -j runtimes devicetypes | python3 -c '
import json, sys
d = json.load(sys.stdin)
rts = [r for r in d["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
rt = sorted(rts, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]
ok = {t["identifier"] for t in rt.get("supportedDeviceTypes", [])}
phones = [t["identifier"] for t in d["devicetypes"] if "iPhone" in t["name"] and (not ok or t["identifier"] in ok)]
print(rt["identifier"], phones[-1])')
fi
echo "ios-launch-floor: $device_type on $runtime"

# The app: App.init takes main_ms, a one-shot display link after the first body takes first_frame_ms,
# then it prints one line and exits.
src="$work/Floor"
app="$work/Floor.app"
mkdir -p "$src"
cat >"$src/main.swift" <<'SWIFT'
import Darwin
import QuartzCore
import SwiftUI

enum Clock {
    static let start: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6
    }()
    static func ms() -> Double { (Date().timeIntervalSince1970 - start) * 1000 }
    static func cpuMs() -> Double {
        var r = rusage()
        getrusage(RUSAGE_SELF, &r)
        func f(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
        return f(r.ru_utime) + f(r.ru_stime)
    }
}

final class FrameMark: NSObject {
    static let shared = FrameMark()
    var mainMs = 0.0, mainCpuMs = 0.0
    private var link: CADisplayLink?
    func arm() {
        guard link == nil else { return }
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ l: CADisplayLink) {
        l.invalidate()
        let frame = Clock.ms()
        print(String(format: "FLOORTTI {\"main_ms\":%.1f,\"main_cpu_ms\":%.1f,\"first_frame_ms\":%.1f}", mainMs, mainCpuMs, frame))
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }
}

@main
struct FloorApp: App {
    init() {
        FrameMark.shared.mainMs = Clock.ms()
        FrameMark.shared.mainCpuMs = Clock.cpuMs()
    }
    var body: some Scene {
        WindowGroup {
            List(0 ..< 30, id: \.self) { Text("Row \($0)") }
                .onAppear { FrameMark.shared.arm() }
        }
    }
}
SWIFT
cat >"$work/Info.plist.in" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>@ID@</string>
<key>CFBundleExecutable</key><string>Floor</string>
<key>CFBundleName</key><string>Floor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
arch="$(uname -m)"; [[ "$arch" == arm64 ]] || arch=x86_64
target="$arch-apple-ios17.0-simulator"
# Compiled once; every app below only links main.o against its own dylib list.
xcrun -sdk iphonesimulator swiftc -O -parse-as-library -target "$target" -c "$src/main.swift" -o "$work/main.o"

# make_app DIR BUNDLE_ID [LINK_ARGS...]
make_app() {
  local dir="$1" id="$2"
  shift 2
  mkdir -p "$dir"
  sed "s/@ID@/$id/" "$work/Info.plist.in" >"$dir/Info.plist"
  xcrun -sdk iphonesimulator swiftc -target "$target" "$work/main.o" -o "$dir/Floor" "$@" || return 1
  codesign --force --sign - "$dir" >/dev/null
}

# dylib_args PATH: the linker arguments (one per line) that make the floor link PATH; none for a
# Swift runtime dylib, an @rpath one or anything that is not a system framework or /usr/lib dylib.
dylib_args() {
  local path="$1" n
  case "$path" in
    /System/Library/Frameworks/*.framework/*)
      printf '%s\n' -Xlinker -framework -Xlinker "$(basename "${path%%.framework/*}")" ;;
    /System/Library/PrivateFrameworks/*.framework/*)
      printf '%s\n' -Xlinker -F/System/Library/PrivateFrameworks -Xlinker -framework -Xlinker "$(basename "${path%%.framework/*}")" ;;
    /usr/lib/swift/*) ;;
    /usr/lib/lib*.dylib)
      n="$(basename "$path" .dylib)"; n="${n#lib}"; n="${n%%.*}"
      printf '%s\n' -Xlinker "-l$n" ;;
  esac
}

boot_sim() {
  udid="$(xcrun simctl create "ios-launch-floor-${GITHUB_RUN_ID:-local}" "$device_type" "$runtime")"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
}

# launch NAME [BUNDLE_ID]: one launch; waits (bounded) for the app's line in its stdout file.
launch() {
  local f="$work/launch-$1.out" i
  : >"$f"
  xcrun simctl launch --terminate-running-process --stdout="$f" "$udid" "${2:-dev.cmux.launchfloor}" >/dev/null
  for ((i = 0; i < 300; i++)); do
    if grep -q '^FLOORTTI ' "$f"; then grep -m1 '^FLOORTTI ' "$f" | sed 's/^FLOORTTI //'; return 0; fi
    sleep 0.1
  done
  echo "ios-launch-floor: launch $1 printed no FLOORTTI line in 30 s" >&2
  return 1
}

# CMUX_LAUNCH_FLOOR_EACH=1 (with CMUX_LAUNCH_FLOOR_LINK_LIKE): one floor app per system dylib the
# binary links, each linking only that one, plus the plain floor; all installed on one simulator and
# launched round-robin (CMUX_LAUNCH_FLOOR_EACH_RUNS measured rounds, default 3, after one unmeasured
# round) so drift hits every app alike. OUT_JSON lists each dylib's main_ms p50 and its margin over
# the plain floor's, largest first: which of the link list's dylibs cost the most before main alone.
if [[ -n "${CMUX_LAUNCH_FLOOR_EACH:-}" ]]; then
  [[ -n "${CMUX_LAUNCH_FLOOR_LINK_LIKE:-}" ]] || { echo "ios-launch-floor: CMUX_LAUNCH_FLOOR_EACH needs CMUX_LAUNCH_FLOOR_LINK_LIKE" >&2; exit 2; }
  each_runs="${CMUX_LAUNCH_FLOOR_EACH_RUNS:-3}"
  ids=(dev.cmux.launchfloor)
  names=(plain)
  make_app "$work/each-0.app" dev.cmux.launchfloor
  i=0
  while read -r path; do
    args=()
    while IFS= read -r a; do args+=("$a"); done < <(dylib_args "$path")
    ((${#args[@]})) || continue
    i=$((i + 1))
    if make_app "$work/each-$i.app" "dev.cmux.launchfloor.f$i" "${args[@]}"; then
      ids+=("dev.cmux.launchfloor.f$i")
      names+=("$path")
    else
      echo "ios-launch-floor: $path did not link alone; skipped" >&2
    fi
  done < <(otool -L "$CMUX_LAUNCH_FLOOR_LINK_LIKE" | tail -n +2 | awk '{print $1}')
  echo "ios-launch-floor: ${#ids[@]} floor apps (plain + one per dylib), $each_runs rounds"
  boot_sim
  for ((k = 0; k < ${#ids[@]}; k++)); do xcrun simctl install "$udid" "$work/each-$k.app"; done
  : >"$work/each.jsonl"
  for ((r = 0; r <= each_runs; r++)); do
    for ((k = 0; k < ${#ids[@]}; k++)); do
      line="$(launch "e$k-r$r" "${ids[$k]}")" || continue
      if ((r > 0)); then printf '{"k":%d,"s":%s}\n' "$k" "$line" >>"$work/each.jsonl"; fi
    done
  done
  printf '%s\n' "${names[@]}" >"$work/each-names.txt"
  python3 - "$work/each.jsonl" "$work/each-names.txt" "$out_json" "$device_type" "$runtime" "$each_runs" <<'PY'
import json, pathlib, statistics, sys
rows = [json.loads(l) for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip()]
names = pathlib.Path(sys.argv[2]).read_text().splitlines()
by = {}
for r in rows:
    by.setdefault(r["k"], []).append(r["s"])
def p50(xs):
    return round(statistics.median(xs)) if xs else None
plain = by.get(0, [])
base_main = p50([s["main_ms"] for s in plain])
base_frame = p50([s["first_frame_ms"] for s in plain])
each = []
for k, name in enumerate(names[1:], start=1):
    s = by.get(k, [])
    m = p50([x["main_ms"] for x in s])
    f = p50([x["first_frame_ms"] for x in s])
    each.append({"dylib": name, "n": len(s), "main_ms_p50": m, "first_frame_ms_p50": f,
                 "main_ms_over_plain": None if m is None or base_main is None else m - base_main,
                 "main_ms_samples": [round(x["main_ms"]) for x in s]})
each.sort(key=lambda e: -(e["main_ms_over_plain"] if e["main_ms_over_plain"] is not None else -1e9))
out = {"device_type": sys.argv[4], "runtime": sys.argv[5], "launch": "simctl launch, warm, round-robin",
       "rounds": int(sys.argv[6]), "plain": {"n": len(plain), "main_ms_p50": base_main, "first_frame_ms_p50": base_frame,
       "main_ms_samples": [round(x["main_ms"]) for x in plain]}, "each": each}
pathlib.Path(sys.argv[3]).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(sys.argv[3]).write_text(json.dumps(out, indent=1) + "\n")
print("LAUNCHFLOOREACH " + json.dumps({"plain": out["plain"]["main_ms_p50"], "top": [(e["dylib"].split("/")[-1], e["main_ms_over_plain"]) for e in each[:15]]}))
PY
  exit 0
fi

link_args=()
linked=0
if [[ -n "${CMUX_LAUNCH_FLOOR_LINK_LIKE:-}" ]]; then
  while read -r path; do
    args=()
    while IFS= read -r a; do args+=("$a"); done < <(dylib_args "$path")
    ((${#args[@]})) || continue
    link_args+=("${args[@]}")
    linked=$((linked + 1))
  done < <(otool -L "$CMUX_LAUNCH_FLOOR_LINK_LIKE" | tail -n +2 | awk '{print $1}')
  echo "ios-launch-floor: linking $linked system dylibs like $CMUX_LAUNCH_FLOOR_LINK_LIKE"
fi
make_app "$app" dev.cmux.launchfloor ${link_args[@]+"${link_args[@]}"}
otool -L "$app/Floor" | tail -n +2 | wc -l | awk '{print "ios-launch-floor: Floor links " $1 " dylibs"}'

boot_sim
xcrun simctl install "$udid" "$app"

launch warmup >/dev/null || true
: >"$work/samples.jsonl"
for ((n = 1; n <= runs; n++)); do
  launch "$n" >>"$work/samples.jsonl" || true
  sleep 0.5
done

python3 - "$work/samples.jsonl" "$out_json" "$device_type" "$runtime" "$linked" <<'PY'
import json, math, pathlib, sys
rows = [json.loads(l) for l in pathlib.Path(sys.argv[1]).read_text().splitlines() if l.strip()]
def rank(xs, p):
    s = sorted(xs)
    return round(s[max(0, math.ceil(p / 100 * len(s)) - 1)]) if s else None
out = {"device_type": sys.argv[3], "runtime": sys.argv[4], "n": len(rows), "launch": "simctl launch, warm", "linked_like_app": int(sys.argv[5])}
for k in ("main_ms", "main_cpu_ms", "first_frame_ms"):
    xs = [r[k] for r in rows if isinstance(r.get(k), (int, float))]
    out[k] = {"samples": [round(x) for x in xs], "p50": rank(xs, 50), "p90": rank(xs, 90)}
pathlib.Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(sys.argv[2]).write_text(json.dumps(out, indent=1) + "\n")
print("LAUNCHFLOOR " + json.dumps(out))
PY
