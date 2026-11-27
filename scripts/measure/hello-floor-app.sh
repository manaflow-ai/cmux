#!/usr/bin/env bash
# hello_floor_app DIR BUNDLE_ID: builds DIR/HelloFloor.app, the empty one-window AppKit app whose launch is the floor
# any AppKit app pays (cmux#60432: finished_launching p50 124.9 ms on a pool M4). Ad hoc signed, no Xcode project.
# Sourced by hello-appkit-floor.sh (the floor alone) and launch-ready.sh floor=1 (the floor as one more side of the
# same step, so cmux's number and the floor come from one harness, one host, one run).
# The app quits on its own once its window drew (or after 5 s), writing its marks to $HELLO_FLOOR_OUT
# (default /tmp/hello-floor-out.json; `open -a` passes no environment).
hello_floor_app() {
  local WORK="$1" APP_ID="$2" TARGET
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
  # Build for the plist's LSMinimumSystemVersion, not swiftc's default (the host's sw_vers version). On a worker whose
  # sw_vers reads newer than the OS Launch Services checks (2026-11-27, a Mac16,11 at ProductVersion 27.0.1, build
  # 26A434), the default minos made every open fail with -10825 kLSIncompatibleSystemVersionErr and the step had n=0.
  TARGET="$(uname -m)-apple-macos13.0"
  xcrun swiftc -O -target "$TARGET" -o "$WORK/HelloFloor.app/Contents/MacOS/HelloFloor" "$WORK/app.swift" || return 1
  xcrun vtool -show-build "$WORK/HelloFloor.app/Contents/MacOS/HelloFloor" 2>/dev/null | grep -E 'minos|sdk' | tr -s ' ' | tr '\n' ' ' || true; echo
  codesign --force --sign - "$WORK/HelloFloor.app" || return 1
}
