// benchhelper: the window and app-state probes xbench.py needs from AppKit.
//
//   benchhelper wait-window PATH_PREFIX TIMEOUT_S   first on-screen window >= 300x200 with alpha > 0
//                                                   of a process whose executable is under PATH_PREFIX;
//                                                   prints "<epoch ms> <pid> <w>x<h>", exit 1 on timeout
//   benchhelper windows PID                         the pid's on-screen windows as JSON lines
//   benchhelper hide PID | unhide PID               NSRunningApplication hide/unhide (no TCC needed)
//   benchhelper ishidden PID                        exit 0 when the app is hidden, 1 when it is not
//   benchhelper terminate PID                       NSRunningApplication terminate (a clean Quit)
//   benchhelper frontmost                           the frontmost app's pid
//   benchhelper displays                            active displays as JSON (count, size, refresh)
//
// CGWindowList owner pids and bounds need no Screen Recording permission
// (window titles would). Compiled once per worker by xbench.py with swiftc -O.
import AppKit
import CoreGraphics
import Foundation

@_silgen_name("proc_pidpath")
private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

private func executablePath(_ pid: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let count = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress!, 4096) }
    return count > 0 ? String(cString: buffer) : ""
}

private func onScreenWindows() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
}

private func size(of window: [String: Any]) -> (Double, Double) {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return ((bounds["Width"] as? Double) ?? 0, (bounds["Height"] as? Double) ?? 0)
}

private func epochMs() -> Double { Date().timeIntervalSince1970 * 1000 }

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: benchhelper wait-window|windows|hide|unhide|ishidden|frontmost|displays ...") }

switch arguments[1] {
case "wait-window":
    guard arguments.count == 4, let timeout = Double(arguments[3]) else { fail("usage: benchhelper wait-window PATH_PREFIX TIMEOUT_S") }
    let prefixes = [arguments[2], arguments[2].replacingOccurrences(of: "/private/", with: "/")]
    var paths: [Int32: String] = [:]
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        for window in onScreenWindows() {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  ((window[kCGWindowAlpha as String] as? Double) ?? 0) > 0 else { continue }
            let (width, height) = size(of: window)
            guard width >= 300, height >= 200 else { continue }
            let path = paths[pid] ?? executablePath(pid)
            paths[pid] = path
            if prefixes.contains(where: { path.hasPrefix($0) }) {
                print(String(format: "%.1f %d %.0fx%.0f", epochMs(), pid, width, height))
                exit(0)
            }
        }
        usleep(2000)  // 2 ms poll: the launch row's resolution
    }
    exit(1)
case "windows":
    guard arguments.count == 3, let pid = Int32(arguments[2]) else { fail("usage: benchhelper windows PID") }
    for window in onScreenWindows() where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
        let (width, height) = size(of: window)
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        print("{\"w\": \(width), \"h\": \(height), \"layer\": \(layer)}")
    }
case "ishidden":
    guard arguments.count == 3, let pid = Int32(arguments[2]),
          let app = NSRunningApplication(processIdentifier: pid) else { fail("no running app for that pid") }
    exit(app.isHidden ? 0 : 1)
case "hide", "unhide", "terminate":
    guard arguments.count == 3, let pid = Int32(arguments[2]),
          let app = NSRunningApplication(processIdentifier: pid) else { fail("no running app for that pid") }
    let done: Bool
    switch arguments[1] {
    case "hide": done = app.hide()
    case "unhide": done = app.unhide()
    default: done = app.terminate()
    }
    exit(done ? 0 : 1)
case "frontmost":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
case "displays":
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    let list = ids.prefix(Int(count)).map { id -> String in
        let mode = CGDisplayCopyDisplayMode(id)
        return "{\"w\": \(CGDisplayPixelsWide(id)), \"h\": \(CGDisplayPixelsHigh(id)), \"hz\": \(mode?.refreshRate ?? 0), \"builtin\": \(CGDisplayIsBuiltin(id) != 0)}"
    }
    print("{\"count\": \(count), \"displays\": [\(list.joined(separator: ", "))]}")
default:
    fail("unknown command \(arguments[1])")
}
