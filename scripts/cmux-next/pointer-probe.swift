// pointer-probe: the real pointer and the real cursor, for GUI proofs on an input host
// (`nx-remote --needs input`; omnibar-pointer-real.py builds and runs it).
//
//   pointer-probe move X Y     post a mouse move (needs an Accessibility grant; the proof moves through cua-driver)
//   pointer-probe path X0 Y0 X1 Y1 N   post N mouse moves along a line, about 120 Hz, as a mouse does
//   pointer-probe drag X0 Y0 X1 Y1 N   press at the start, N left-drag events along a line, release at the end
//   pointer-probe owner X Y    print the app and title of the frontmost on-screen window at a screen point (top left)
//   pointer-probe where        print the pointer (screen points from the top left)
//   pointer-probe click X Y    post a left press and release there
//   pointer-probe cursor       print the cursor on screen now: iBeam, arrow, or other:<hot spot> <size>
//   pointer-probe screen       print the main screen's height in points
import AppKit

_ = NSApplication.shared
let args = CommandLine.arguments

func point() -> CGPoint {
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else {
        FileHandle.standardError.write("usage: pointer-probe move|click X Y\n".data(using: .utf8)!)
        exit(2)
    }
    return CGPoint(x: x, y: y)
}

func post(_ type: CGEventType, at location: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func same(_ a: NSCursor, _ b: NSCursor) -> Bool {
    a.hotSpot == b.hotSpot && a.image.size == b.image.size
}

switch args.count > 1 ? args[1] : "" {
case "move":
    post(.mouseMoved, at: point())
case "path":
    guard args.count >= 7, let x0 = Double(args[2]), let y0 = Double(args[3]), let x1 = Double(args[4]), let y1 = Double(args[5]),
          let steps = Int(args[6]), steps > 0 else {
        FileHandle.standardError.write("usage: pointer-probe path X0 Y0 X1 Y1 N\n".data(using: .utf8)!)
        exit(2)
    }
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        post(.mouseMoved, at: CGPoint(x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t))
        usleep(8_000) // a mouse reports about every 8 ms; the window server coalesces faster posts
    }
case "drag":
    guard args.count >= 7, let x0 = Double(args[2]), let y0 = Double(args[3]), let x1 = Double(args[4]), let y1 = Double(args[5]),
          let steps = Int(args[6]), steps > 0 else {
        FileHandle.standardError.write("usage: pointer-probe drag X0 Y0 X1 Y1 N\n".data(using: .utf8)!)
        exit(2)
    }
    post(.leftMouseDown, at: CGPoint(x: x0, y: y0))
    usleep(50_000)
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        post(.leftMouseDragged, at: CGPoint(x: x0 + (x1 - x0) * t, y: y0 + (y1 - y0) * t))
        usleep(16_000)
    }
    usleep(100_000) // the pointer rests over the end before the release, as a hand does
    post(.leftMouseUp, at: CGPoint(x: x1, y: y1))
case "owner":
    let location = point()
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let hit = windows.first { info in
        guard let bounds = info[kCGWindowBounds as String] as? [String: Double], (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return false }
        return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(location)
    }
    print(hit.map { "\($0[kCGWindowOwnerName as String] ?? "?") layer \($0[kCGWindowLayer as String] ?? "?") "
        + "title \($0[kCGWindowName as String] ?? "") bounds \($0[kCGWindowBounds as String] ?? "")" } ?? "none")
case "where":
    let location = CGEvent(source: nil)?.location ?? .zero
    print("\(location.x) \(location.y)")
case "click":
    let location = point()
    post(.leftMouseDown, at: location)
    post(.leftMouseUp, at: location)
case "cursor":
    guard let cursor = NSCursor.currentSystem else {
        print("none")
        break
    }
    print(same(cursor, .iBeam) ? "iBeam" : same(cursor, .arrow) ? "arrow" : "other:\(cursor.hotSpot) \(cursor.image.size)")
case "screen":
    print(NSScreen.screens.first?.frame.height ?? 0)
default:
    FileHandle.standardError.write("usage: pointer-probe move|click X Y | cursor | screen\n".data(using: .utf8)!)
    exit(2)
}
