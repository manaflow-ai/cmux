// Window and display facts for the release-media host agent.
//
// Compiled once per host by host_agent.py (`xcrun swiftc -O`). Reading window
// bounds, owners, and display modes needs no Screen Recording permission; only
// `preflight` reports whether *this* process (so its SSH-responsible parent)
// may capture the screen.
//
//   window_probe windows <pid>   JSON list of that pid's on-screen windows, front to back
//   window_probe display         JSON main display points, pixels, and backing scale
//   window_probe preflight       JSON {"screenRecording": bool}

import CoreGraphics
import Foundation

func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func onScreenWindows() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
}

func describe(_ info: [String: Any]) -> [String: Any] {
    let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return [
        "id": info[kCGWindowNumber as String] as? Int ?? 0,
        "layer": info[kCGWindowLayer as String] as? Int ?? 0,
        "owner": info[kCGWindowOwnerName as String] as? String ?? "",
        "pid": info[kCGWindowOwnerPID as String] as? Int ?? 0,
        "alpha": info[kCGWindowAlpha as String] as? Double ?? 1,
        "x": bounds["X"] as? Double ?? 0,
        "y": bounds["Y"] as? Double ?? 0,
        "width": bounds["Width"] as? Double ?? 0,
        "height": bounds["Height"] as? Double ?? 0,
    ]
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: window_probe windows <pid> | display | preflight\n".data(using: .utf8)!)
    exit(64)
}

switch args[1] {
case "windows":
    guard args.count >= 3, let pid = Int(args[2]) else { exit(64) }
    emit(onScreenWindows().map(describe).filter { $0["pid"] as? Int == pid })
case "display":
    let display = CGMainDisplayID()
    guard let mode = CGDisplayCopyDisplayMode(display) else { exit(1) }
    let scale = mode.width > 0 ? Double(mode.pixelWidth) / Double(mode.width) : 1
    emit([
        "pointsWide": mode.width,
        "pointsHigh": mode.height,
        "pixelsWide": mode.pixelWidth,
        "pixelsHigh": mode.pixelHeight,
        "scale": scale,
    ])
case "preflight":
    emit(["screenRecording": CGPreflightScreenCaptureAccess()])
default:
    exit(64)
}
