// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import Darwin
import Foundation

/// `bench-pointer --pointer-glide X0 Y0 X1 Y1 STEPS [--interval-ms MS]` posts
/// STEPS real mouse-moved events along the line from (X0, Y0) to (X1, Y1)
/// (screen points, top left), MS apart (8, as a mouse reports), under this
/// app's own grants. Dev measurement only: the hover card bench
/// (scripts/cmux-next/hover-instant-bench.py) needs moves the window server
/// routes to the app's tracking areas, and only a binary with a lasting
/// Accessibility grant can post them on a bench host. A tool compiled per run
/// never holds one, and CuaDriver's move_cursor warps without an event.
///
/// It never asks for a grant. It prints one JSON object: `posted`, and
/// `last_post_uptime_ns`, CLOCK_UPTIME_RAW when the last move was posted (the
/// clock Python's time.monotonic reads on macOS), so the caller times from the
/// move and not from this process's exit. Exit 0, 2 on bad arguments, 3 when
/// this process may not post events.
public struct PointerGlide {
    public static let flag = "--pointer-glide"

    public init() {}

    public func main(arguments: [String]) -> Int32 {
        guard let start = arguments.firstIndex(of: Self.flag) else { return Self.usage() }
        let values = arguments.dropFirst(start + 1).prefix(5)
        let numbers = values.compactMap(Double.init)
        guard numbers.count == 5, let steps = Int(exactly: numbers[4]), (1...1000).contains(steps) else {
            return Self.usage()
        }
        var interval = 8.0
        if let index = arguments.firstIndex(of: "--interval-ms") {
            guard let value = arguments.dropFirst(index + 1).first.flatMap(Double.init), (0...100).contains(value) else {
                return Self.usage()
            }
            interval = value
        }
        guard CGPreflightPostEventAccess() else {
            print(Self.json(["ok": false, "error": "no post-event access", "ax_trusted": AXIsProcessTrusted(),
                             "post_access": false]))
            return 3
        }
        let (x0, y0, x1, y1) = (numbers[0], numbers[1], numbers[2], numbers[3])
        var posted = 0
        var last: UInt64 = 0
        for step in 1...steps {
            if step > 1 { usleep(useconds_t(interval * 1000)) }
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                                      mouseButton: .left) else { continue }
            event.post(tap: .cghidEventTap)
            last = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            posted += 1
        }
        let here = CGEvent(source: nil)?.location ?? .zero
        print(Self.json(["ok": posted == steps, "posted": posted, "last_post_uptime_ns": last,
                         "pointer": [here.x, here.y]]))
        return posted == steps ? 0 : 3
    }

    static func usage() -> Int32 {
        FileHandle.standardError.write(Data("usage: cmux-cua-helper --pointer-glide X0 Y0 X1 Y1 STEPS [--interval-ms MS]\n".utf8))
        return 2
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
