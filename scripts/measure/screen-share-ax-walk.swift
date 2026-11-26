// Accessibility driver for scripts/measure/screen-share-ax-walk.sh: drives one running app (by bundle id) through
// a Screen Sharing entry point and walks its windows down for an identifier, the way hq's feature-flow probe judges
// `{"expect": {"ax": {"identifier": "macScreen.home"}}}`.
//   ssax BUNDLE trusted                 exit 0 when this process has the Accessibility grant
//   ssax BUNDLE activate                make the app the active one
//   ssax BUNDLE key CHORD               post CHORD (cmd+shift+s, cmd+shift+p, return, escape) to the app
//   ssax BUNDLE type TEXT               type TEXT into the app
//   ssax BUNDLE menu TOP ITEM           AXPress the menu bar's TOP > ITEM (a picked item, not its shortcut)
//   ssax BUNDLE hover ID                move the pointer to the center of the first element with identifier ID
//   ssax BUNDLE click ID                click the center of the first element with identifier ID
//   ssax BUNDLE menuitem LABEL          AXPress the first AXMenuItem titled LABEL anywhere in the app's tree
//   ssax BUNDLE wait ID SECONDS         walk every window of the app once a second until ID shows or SECONDS pass;
//                                       prints one JSON line: found, elements read, whether the walk was complete
//                                       (no element, depth or time bound cut it), each window's count, and
//                                       whether cmux.topPage.home showed
// Exit: 0 done/found, 1 not found, 2 usage, no grant or no app.
import AppKit
import ApplicationServices
import Foundation

let args = CommandLine.arguments
func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}
guard args.count >= 3 else { fail("usage: ssax BUNDLE trusted|activate|key|type|menu|hover|click|menuitem|wait ...") }
let bundle = args[1], verb = args[2]
if verb == "trusted" { print(AXIsProcessTrusted() ? "trusted" : "untrusted"); exit(AXIsProcessTrusted() ? 0 : 2) }
guard AXIsProcessTrusted() else { fail("untrusted: no Accessibility grant") }
guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
    .max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else { fail("no running app \(bundle)") }
let pid = running.processIdentifier
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3.0)

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, "AXChildren") as? [AXUIElement]) ?? [] }

let elementCap = 40000, depthCap = 120, timeCap = 20.0
struct Walk { var read = 0; var cut = ""; var hits: [String: Int] = [:] }
func walk(_ root: AXUIElement, want: Set<String>, into w: inout Walk, started: Date) {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    while let item = stack.popLast() {
        let (e, depth) = item
        if w.read >= elementCap { w.cut = "element cap \(elementCap)"; return }
        if Date().timeIntervalSince(started) > timeCap { w.cut = "time cap \(Int(timeCap)) s"; return }
        w.read += 1
        let id = str(e, "AXIdentifier")
        if want.contains(id) { w.hits[id, default: 0] += 1 }
        if depth >= depthCap { w.cut = "depth cap \(depthCap)"; continue }
        for c in children(e).reversed() { stack.append((c, depth + 1)) }
    }
}
func windows() -> [AXUIElement] { (attr(app, "AXWindows") as? [AXUIElement]) ?? [] }
func first(_ match: (AXUIElement) -> Bool, under roots: [AXUIElement]) -> AXUIElement? {
    var stack = roots.reversed().map { ($0, 0) }, seen = 0
    while let item = stack.popLast() {
        let (e, depth) = item
        seen += 1
        if seen > elementCap { return nil }
        if match(e) { return e }
        if depth < depthCap { for c in children(e).reversed() { stack.append((c, depth + 1)) } }
    }
    return nil
}
func byID(_ id: String) -> AXUIElement? { first({ str($0, "AXIdentifier") == id }, under: windows()) }
func center(_ e: AXUIElement) -> CGPoint? {
    guard let p = attr(e, "AXPosition"), let s = attr(e, "AXSize") else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
}
let keyCodes: [String: CGKeyCode] = ["s": 1, "p": 35, "return": 36, "escape": 53, "t": 17, "w": 13]
func post(_ code: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}
func activate() -> Bool {
    for _ in 0..<20 {
        running.activate(options: [.activateAllWindows])
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        usleep(250_000)
    }
    return false
}

switch verb {
case "activate":
    exit(activate() ? 0 : 1)
case "key" where args.count >= 4:
    _ = activate()
    var flags: CGEventFlags = []
    var key = ""
    for part in args[3].lowercased().split(separator: "+") {
        switch part {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "alt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: key = String(part)
        }
    }
    guard let code = keyCodes[key] else { fail("unknown key \(key)") }
    post(code, flags: flags)
case "type" where args.count >= 4:
    _ = activate()
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in args[3].utf16 {
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
            var c = ch
            ev.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            ev.post(tap: .cghidEventTap)
            usleep(15_000)
        }
    }
case "menu" where args.count >= 5:
    guard let bar = attr(app, "AXMenuBar") else { fail("no menu bar", 1) }
    let barItems = children(bar as! AXUIElement)
    guard let top = barItems.first(where: { str($0, "AXTitle") == args[3] }) else {
        fail("no menu bar item \(args[3]); bar: \(barItems.map { str($0, "AXTitle") })", 1)
    }
    guard let item = first({ str($0, "AXRole") == "AXMenuItem" && str($0, "AXTitle") == args[4] }, under: [top]) else {
        fail("no \(args[3]) > \(args[4])", 1)
    }
    let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
    print("pressed \(args[3]) > \(args[4]) (\(err.rawValue))")
case "hover" where args.count >= 4, "click" where args.count >= 4:
    _ = activate()
    guard let e = byID(args[3]) else { fail("no element \(args[3])", 1) }
    guard let at = center(e) else { fail("element \(args[3]) has no frame", 1) }
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
    if verb == "click" {
        usleep(150_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
    }
    print("\(verb) \(args[3]) at \(Int(at.x)),\(Int(at.y))")
case "menuitem" where args.count >= 4:
    var roots = [app]
    if let focused = attr(app, "AXFocusedUIElement") { roots.append(focused as! AXUIElement) }
    guard let item = first({ str($0, "AXRole") == "AXMenuItem" && str($0, "AXTitle") == args[3] }, under: roots) else {
        fail("no AXMenuItem \(args[3])", 1)
    }
    let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
    print("pressed menu item \(args[3]) (\(err.rawValue))")
case "wait" where args.count >= 5:
    let want = args[3], seconds = Double(args[4]) ?? 10
    let deadline = Date().addingTimeInterval(seconds)
    var last = Walk(), counts: [Int] = [], tries = 0
    repeat {
        tries += 1
        var w = Walk()
        counts = []
        let started = Date()
        for window in windows() {
            let before = w.read
            walk(window, want: [want, "cmux.topPage.home"], into: &w, started: started)
            counts.append(w.read - before)
        }
        last = w
        if (w.hits[want] ?? 0) > 0 { break }
        usleep(1_000_000)
    } while Date() < deadline
    let found = (last.hits[want] ?? 0) > 0
    let row: [String: Any] = [
        "identifier": want, "found": found, "matches": last.hits[want] ?? 0,
        "elements_read": last.read, "elements_complete": last.cut.isEmpty, "cut": last.cut,
        "windows": counts, "top_page_home": (last.hits["cmux.topPage.home"] ?? 0) > 0, "walks": tries,
    ]
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(found ? 0 : 1)
default:
    fail("usage: ssax BUNDLE trusted|activate|key CHORD|type TEXT|menu TOP ITEM|hover ID|click ID|menuitem LABEL|wait ID S")
}
