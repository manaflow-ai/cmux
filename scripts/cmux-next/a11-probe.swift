// a11-probe: what competitor-bench.py (pro audit 11) asks the window server, in a process of its own.
//
//   a11-probe grants                         {"screen_capture":B,"post_event":B,"accessibility":B} (preflight only:
//                                            it never asks for a grant, so no dialog opens on the host)
//   a11-probe wait-window --pid P[,P2] [--timeout S] [--min 200]
//                                            polls CGWindowListCopyWindowInfo every 1 ms until a layer-0 window of
//                                            one of the pids is on screen and at least --min points wide and high;
//                                            prints `window UPTIME_NS PID W H` (CLOCK_UPTIME_RAW) or exits 1
//   a11-probe windows --pid P                one JSON line per on-screen window of P (id, layer, bounds)
//
// Window metadata (owner, bounds, layer) needs no Screen Recording grant; only titles and pixels do.
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func value(_ flag: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func windows(of pids: Set<Int32>) -> [[String: Any]] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return list.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? Int32) ?? -1) }
}

func bounds(_ window: [String: Any]) -> CGRect {
    guard let dict = window[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return .zero }
    return rect
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "grants":
    let grants: [String: Bool] = [
        "screen_capture": CGPreflightScreenCaptureAccess(),
        "post_event": CGPreflightPostEventAccess(),
        "listen_event": CGPreflightListenEventAccess(),
        "accessibility": AXIsProcessTrusted(),
    ]
    let data = (try? JSONSerialization.data(withJSONObject: grants, options: [.sortedKeys])) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
case "wait-window":
    let pids = Set((value("--pid", args) ?? "").split(separator: ",").compactMap { Int32($0) })
    let timeout = Double(value("--timeout", args) ?? "60") ?? 60
    let minimum = Double(value("--min", args) ?? "200") ?? 200
    if pids.isEmpty { FileHandle.standardError.write(Data("a11-probe: --pid\n".utf8)); exit(2) }
    let end = uptimeNs() + UInt64(timeout * 1e9)
    while uptimeNs() < end {
        for window in windows(of: pids) where ((window[kCGWindowLayer as String] as? Int) ?? 1) == 0 {
            let rect = bounds(window)
            if rect.width >= minimum && rect.height >= minimum {
                let owner = (window[kCGWindowOwnerPID as String] as? Int32) ?? 0
                print("window \(uptimeNs()) \(owner) \(Int(rect.width)) \(Int(rect.height))")
                exit(0)
            }
        }
        usleep(1000)
    }
    print("timeout")
    exit(1)
case "windows":
    let pids = Set((value("--pid", args) ?? "").split(separator: ",").compactMap { Int32($0) })
    for window in windows(of: pids) {
        let rect = bounds(window)
        let id = (window[kCGWindowNumber as String] as? Int) ?? 0
        let layer = (window[kCGWindowLayer as String] as? Int) ?? 0
        print("{\"id\":\(id),\"layer\":\(layer),\"x\":\(Int(rect.minX)),\"y\":\(Int(rect.minY)),\"w\":\(Int(rect.width)),\"h\":\(Int(rect.height))}")
    }
default:
    FileHandle.standardError.write(Data("usage: a11-probe grants | wait-window --pid P | windows --pid P\n".utf8))
    exit(2)
}
