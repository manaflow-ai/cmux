// pointer-probe: the real pointer and the real cursor, for GUI proofs on an input host
// (`nx-remote --needs input`; omnibar-pointer-real.py builds and runs it).
//
//   pointer-probe move X Y     post a mouse move (needs an Accessibility grant; the proof moves through cua-driver)
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
