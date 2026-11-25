#!/usr/bin/env bash
# The LaunchServices floor for any AppKit app's first window on a warm relaunch.
# Builds a one-window AppKit app with swiftc (ad-hoc signed, no Xcode project), then launches
# it REPS times through LaunchServices and reports, in ms after the open request:
#   proc_start (kernel p_starttime), main, did_finish_launching, first CATransaction commit
#   after the window is ordered front, and the window's occlusion state turning visible.
# Two arms, alternating per rep: `open -a` (a CLI request, as asked) and NSWorkspace.openApplication
# from an already-running process (what the Dock does, without `open`'s own exec).
# One priming launch per arm first (warm). Each launch quits on its own and the next waits for its exit.
#
# Usage: scripts/measure/hello-appkit-floor.sh [reps=12] [gap_ms=1000]
# Fleet: cmux-ci run --class exclusive --measurement --label measure --display \
#          --script scripts/measure/hello-appkit-floor.sh --ref SHA --queue-timeout 20
# Measurement only. Writes nothing outside its own temp dir, which it removes.
set -euo pipefail
# Launches only work from the console user's GUI session: run the whole step there (build included, so its files
# belong to that user).
if [[ "${1:-}" != inner ]]; then
  ROOT="$(git rev-parse --show-toplevel)"
  cd "$ROOT"
  GITHUB_WORKSPACE="$ROOT" exec scripts/ci/frame-pacing/console-session.sh "$ROOT/scripts/measure/hello-appkit-floor.sh" inner "$@"
fi
shift
REPS=12
GAP_MS=1000
for a in "$@"; do
  case "$a" in
    reps=*) REPS="${a#reps=}" ;;
    gap_ms=*) GAP_MS="${a#gap_ms=}" ;;
    *) echo "unknown arg $a" >&2; exit 2 ;;
  esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hello-floor.XXXXXX")"
APP_ID="dev.cmux.measure.hellofloor.$$"
cleanup() {
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$WORK/HelloFloor.app" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== host (manager=$(launchctl managername 2>/dev/null) user=$(id -un))"
echo "host=$(scutil --get ComputerName 2>/dev/null || hostname) model=$(sysctl -n hw.model) cpu=$(sysctl -n machdep.cpu.brand_string)"
sw_vers | tr '\n' ' '; echo
echo "load_before=$(sysctl -n vm.loadavg)"
xcrun swiftc --version 2>&1 | head -1

mkdir -p "$WORK/HelloFloor.app/Contents/MacOS"
cat >"$WORK/HelloFloor.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HelloFloor</string>
<key>CFBundleIdentifier</key><string>$APP_ID</string>
<key>CFBundleName</key><string>HelloFloor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

cat >"$WORK/app.swift" <<'SWIFT'
import AppKit
import Darwin
import QuartzCore

let tMain = clock_gettime_nsec_np(CLOCK_REALTIME)
let outPath = ProcessInfo.processInfo.environment["HELLO_FLOOR_OUT"] ?? "/tmp/hello-floor-out.json"

func procStartNs() -> UInt64 {
  var kp = kinfo_proc()
  var size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
  guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0 else { return 0 }
  let tv = kp.kp_proc.p_starttime
  return UInt64(tv.tv_sec) * 1_000_000_000 + UInt64(tv.tv_usec) * 1000
}

final class Delegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var marks: [String: UInt64] = ["main": tMain]
  var written = false
  func mark(_ k: String) { if marks[k] == nil { marks[k] = clock_gettime_nsec_np(CLOCK_REALTIME) } ; maybeFinish() }
  func maybeFinish() {
    guard !written, marks["commit"] != nil, marks["visible"] != nil else { return }
    written = true
    marks["proc_start"] = procStartNs(); marks["pid"] = UInt64(getpid())
    let body = marks.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
    let tmp = outPath + ".tmp"
    try? ("{" + body + "}\n").write(toFile: tmp, atomically: false, encoding: .utf8)
    rename(tmp, outPath)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
  }
  func applicationDidFinishLaunching(_ n: Notification) {
    mark("did_finish_launching")
    window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "HelloFloor"
    let v = NSView(frame: window.contentLayoutRect)
    v.wantsLayer = true
    v.layer?.backgroundColor = NSColor.systemTeal.cgColor
    window.contentView = v
    NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
      guard let self else { return }
      if self.window.occlusionState.contains(.visible) { self.mark("visible") }
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in self?.mark("commit") }
    window.makeKeyAndOrderFront(nil)
    mark("ordered_front")
    CATransaction.commit()
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      // Never hang the harness: write what we have.
      self?.marks["visible"] = self?.marks["visible"] ?? 0
      self?.marks["commit"] = self?.marks["commit"] ?? 0
      self?.maybeFinish()
    }
  }
}

let app = NSApplication.shared
let d = Delegate()
app.delegate = d
app.setActivationPolicy(.regular)
app.run()
SWIFT

cat >"$WORK/launcher.swift" <<'SWIFT'
import AppKit
import Darwin

// launcher APP OUT REPS GAP_MS
setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments
let appURL = URL(fileURLWithPath: a[1])
let out = a[2]
let reps = Int(a[3])!
let gapMs = Int(a[4])!
let keys = ["proc_start", "main", "did_finish_launching", "ordered_front", "commit", "visible"]
setenv("HELLO_FLOOR_OUT", out, 1)

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_REALTIME) }
func waitFile(_ p: String, timeoutMs: Int) -> String? {
  let end = now() + UInt64(timeoutMs) * 1_000_000
  while now() < end {
    if let s = try? String(contentsOfFile: p, encoding: .utf8), s.hasSuffix("\n") { return s }
    usleep(500)
  }
  return nil
}
func waitGone(_ pid: pid_t) {
  for _ in 0..<2000 {
    if kill(pid, 0) != 0 { return }
    usleep(5000)
  }
}

func launchOnce(_ arm: String) -> [String: Double]? {
  unlink(out)
  let t0 = now()
  if arm == "open" {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", appURL.path]
    p.environment = ProcessInfo.processInfo.environment
    try! p.run()
  } else {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.environment = ["HELLO_FLOOR_OUT": out]
    cfg.activates = true
    NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, err in
      if let err { FileHandle.standardError.write("openApplication: \(err)\n".data(using: .utf8)!) }
    }
  }
  guard let s = waitFile(out, timeoutMs: 15000),
        let obj = try? JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as? [String: NSNumber] else {
    print("arm=\(arm) TIMEOUT"); return nil
  }
  var row: [String: Double] = [:]
  for k in keys { if let v = obj[k]?.uint64Value, v > 0 { row[k] = Double(Int64(v) - Int64(t0)) / 1e6 } }
  if let pid = obj["pid"]?.int32Value { waitGone(pid) }
  return row
}

var rows: [String: [[String: Double]]] = ["open": [], "workspace": []]
for arm in ["open", "workspace"] { _ = launchOnce(arm); usleep(UInt32(gapMs) * 1000) } // priming
for i in 0..<reps {
  for arm in (i % 2 == 0 ? ["open", "workspace"] : ["workspace", "open"]) {
    if let r = launchOnce(arm) {
      rows[arm]!.append(r)
      print("rep=\(i) arm=\(arm) " + keys.map { k in "\(k)=" + (r[k].map { String(format: "%.1f", $0) } ?? "-") }.joined(separator: " "))
    }
    usleep(UInt32(gapMs) * 1000)
  }
}
func pct(_ xs: [Double], _ p: Double) -> Double {
  let s = xs.sorted(); if s.isEmpty { return .nan }
  let idx = min(s.count - 1, Int((p * Double(s.count - 1)).rounded(.up)))
  return s[idx]
}
func median(_ xs: [Double]) -> Double {
  let s = xs.sorted(); if s.isEmpty { return .nan }
  return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
print("== summary (ms after the open request; n per arm)")
for arm in ["open", "workspace"] {
  let rs = rows[arm]!
  print("arm=\(arm) n=\(rs.count) " + keys.map { k in
    let xs = rs.compactMap { $0[k] }
    return "\(k)=p50:\(String(format: "%.1f", median(xs)))/p95:\(String(format: "%.1f", pct(xs, 0.95)))/min:\(String(format: "%.1f", xs.min() ?? .nan))"
  }.joined(separator: " "))
}
SWIFT

echo "== build"
t=$(date +%s)
xcrun swiftc -O -o "$WORK/HelloFloor.app/Contents/MacOS/HelloFloor" "$WORK/app.swift"
xcrun swiftc -O -o "$WORK/launcher" "$WORK/launcher.swift"
codesign --force --sign - "$WORK/HelloFloor.app"
codesign -dv "$WORK/HelloFloor.app" 2>&1 | grep -E 'Signature|Identifier' || true
echo "built in $(( $(date +%s) - t ))s; exe $(stat -f %z "$WORK/HelloFloor.app/Contents/MacOS/HelloFloor") bytes"

echo "== launches reps=$REPS gap_ms=$GAP_MS"
# `open -a` does not pass the launcher's environment, so both arms use the app's default out path.
OUT=/tmp/hello-floor-out.json
"$WORK/launcher" "$WORK/HelloFloor.app" "$OUT" "$REPS" "$GAP_MS"

# Third arm: the same app through launch-ready.sh's own probe (scripts/measure/launch-ready.swift, the harness the
# NIGHTLY number comes from: NSWorkspace.openApplication with a new instance, CGWindowList polled every 1 ms), so the
# floor and the NIGHTLY share one harness. Its times are ms from process start; request_to_start is before it.
echo "== launch-ready probe arm reps=$REPS"
xcrun swiftc -O -o "$WORK/launch-ready" scripts/measure/launch-ready.swift >"$WORK/probe-swiftc.log" 2>&1 \
  || { echo "probe build failed"; cat "$WORK/probe-swiftc.log"; exit 3; }
mkdir -p "$WORK/probe-home"
"$WORK/launch-ready" "$WORK/HelloFloor.app" "$WORK/probe-home" prime 0.3 /tmp/hf-$$.sock >"$WORK/probe-prime.txt" 2>&1 || true
: >"$WORK/probe.jsonl"
for i in $(seq 1 "$REPS"); do
  sleep "$(awk "BEGIN{print $GAP_MS/1000}")"
  "$WORK/launch-ready" "$WORK/HelloFloor.app" "$WORK/probe-home" "run$i" 0.3 /tmp/hf-$$.sock 2>/dev/null \
    | grep '^LR-RUN ' | sed 's/^LR-RUN //' | tee -a "$WORK/probe.jsonl" \
    | python3 -I -c 'import json,sys; r=json.loads(sys.stdin.read()); print("probe", r["label"], "request_to_start=%s window_on_screen=%s finished_launching=%s" % (r["request_to_start"], r["window_on_screen"], r["finished_launching"]))' || echo "probe run$i failed"
done
python3 -I -c '
import json, sys, statistics
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
def p(xs, q):
    xs = sorted(x for x in xs if x is not None)
    if not xs: return None
    import math
    return xs[min(len(xs) - 1, math.ceil(q * (len(xs) - 1)))]
for k in ("request_to_start", "finished_launching", "window_on_screen", "request_to_window"):
    xs = [r.get(k) if k != "request_to_window" else (None if r.get("window_on_screen") is None else r["request_to_start"] + r["window_on_screen"]) for r in rows]
    xs = [x for x in xs if x is not None]
    print("probe_summary n=%d %s p50=%.1f p95=%.1f min=%.1f" % (len(xs), k, statistics.median(xs), p(xs, 0.95), min(xs)) if xs else "probe_summary %s none" % k)
' "$WORK/probe.jsonl"

rm -f "$OUT" "$OUT.tmp" "/tmp/hf-$$.sock"
echo "load_after=$(sysctl -n vm.loadavg)"
