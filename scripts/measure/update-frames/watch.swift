// The window log of scripts/measure/update-click-ab.sh frames=1 (ask-ad4a68e740: "we dont want the transition frames in
// between"): every on-screen window whose owner name contains NAME, sampled every INTERVAL_MS, one JSON line each time
// that set changes: {"t": <epoch ms>, "w": [[pid, window number, layer, alpha, x, y, w, h], ...]} (front to back,
// global points). CGWindowList needs no Screen Recording grant, so a copy compiled on the step works.
//
//   xcrun swiftc -O -o update-frames-watch watch.swift
//   update-frames-watch NAME INTERVAL_MS SECONDS   ends after SECONDS, on SIGTERM, or when stdout closes; the first
//   line is {"display": [w, h]} (the main display, points)
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count == 4, let interval = Int(args[2]), let seconds = Double(args[3]) else {
    FileHandle.standardError.write(Data("usage: update-frames-watch NAME INTERVAL_MS SECONDS\n".utf8))
    exit(2)
}
let name = args[1]
signal(SIGTERM) { _ in exit(0) }
signal(SIGPIPE) { _ in exit(0) }

func sample() -> [[Double]] {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var rows: [[Double]] = []
    for info in list {
        guard let owner = info[kCGWindowOwnerName as String] as? String, owner.contains(name),
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
        let number = info[kCGWindowNumber as String] as? Int ?? 0
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        rows.append([Double(pid), Double(number), Double(layer), (alpha * 1000).rounded() / 1000,
                     Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)])
    }
    return rows
}

let display = CGDisplayBounds(CGMainDisplayID())
print("{\"display\": [\(Int(display.width)), \(Int(display.height))]}")
let end = Date().addingTimeInterval(seconds)
var last: [[Double]]? = nil
while Date() < end {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let rows = sample()
    if last == nil || rows != last! {
        let object: [String: Any] = ["t": now, "w": rows]
        if let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) {
            print(line)
        }
        last = rows
    }
    usleep(useconds_t(interval * 1000))
}
