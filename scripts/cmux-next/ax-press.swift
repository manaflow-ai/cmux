// Accessibility-only driver for a running app, by visible text (for scripts/cmux-next/codex-login-hang.py).
//   ax-press PID trusted                      prints whether this process has the Accessibility grant
//   ax-press PID dump                         prints the app's AX tree (role, title, description, value)
//   ax-press PID press ANCHOR LABEL           in tree order, after the first element whose text contains ANCHOR
//                                             ("" for none), AXPress the first button whose text contains LABEL
//   ax-press PID has TEXT                     exit 0 when some element's text contains TEXT
// Exit: 0 done, 1 not found, 2 usage or no grant.
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write("usage: ax-press PID trusted|dump|press ANCHOR LABEL|has TEXT\n".data(using: .utf8)!)
    exit(2)
}
let verb = args[2]
if verb == "trusted" { print(AXIsProcessTrusted() ? "trusted" : "untrusted"); exit(AXIsProcessTrusted() ? 0 : 2) }
guard AXIsProcessTrusted() else { print("untrusted"); exit(2) }

let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3.0)
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func str(_ element: AXUIElement, _ name: String) -> String { (attr(element, name) as? String) ?? "" }
func text(_ e: AXUIElement) -> String { [str(e, "AXTitle"), str(e, "AXDescription"), str(e, "AXValue")].filter { !$0.isEmpty }.joined(separator: " | ") }

var visited = 0
func walk(_ element: AXUIElement, _ depth: Int, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    visited += 1
    if visited > 20000 || depth > 80 { return false }
    if visit(element, depth) { return true }
    for child in (attr(element, "AXChildren") as? [AXUIElement]) ?? [] {
        if walk(child, depth + 1, visit) { return true }
    }
    return false
}

switch verb {
case "dump":
    _ = walk(app, 0) { e, d in
        let t = text(e)
        print(String(repeating: " ", count: min(d, 40)) + str(e, "AXRole") + (t.isEmpty ? "" : " \"" + String(t.prefix(160)) + "\""))
        return false
    }
case "press" where args.count >= 5:
    let anchor = args[3], label = args[4]
    var anchored = anchor.isEmpty
    var pressed: AXUIElement?
    _ = walk(app, 0) { e, _ in
        let t = text(e)
        if !anchored { if t.contains(anchor) { anchored = true }; return false }
        if str(e, "AXRole") == "AXButton" && t.contains(label) { pressed = e; return true }
        return false
    }
    guard let target = pressed else { print("notfound anchored=\(anchored) visited=\(visited)"); exit(1) }
    let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
    print("pressed \(text(target)) result=\(result.rawValue)")
    exit(result == .success ? 0 : 1)
case "has" where args.count >= 4:
    let needle = args[3]
    let found = walk(app, 0) { e, _ in text(e).contains(needle) }
    print(found ? "found" : "notfound")
    exit(found ? 0 : 1)
default:
    print("unknown verb \(verb)"); exit(2)
}
