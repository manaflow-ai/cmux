// The running app's accessibility tree as JSON, for tests/ui-structure/thread_structure.py normalize.
//
//   swiftc -O tests/ui-structure/ax_dump.swift -o ax_dump && ./ax_dump PID [MAX_DEPTH] > dump.json
//
// It reads what any accessibility client reads (AXUIElement), so the dump is the same whether the
// native transcript or a web page draws the thread: WebKit exposes a page's tree to AX clients too.
// Each node: {role, subrole, role_description, title, label (AXDescription), value (strings only),
// identifier, frame: [x, y, w, h] in screen points with a top-left origin, children}. The root is the
// application; its children are its windows.
//
// Exit 0: dumped. 3: this process is not trusted for accessibility (System Settings > Privacy &
// Security > Accessibility; GitHub's hosted macOS images trust the runner's processes). 2: usage.
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    FileHandle.standardError.write(Data("usage: ax_dump PID [MAX_DEPTH]\n".utf8))
    exit(2)
}
let maxDepth = args.count >= 3 ? Int(args[2]) ?? 60 : 60
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("ax_dump: not trusted for accessibility\n".utf8))
    exit(3)
}

let app = AXUIElementCreateApplication(pid)
// WebKit and Chromium build a page's tree for an assistive client that asks for it.
AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetMessagingTimeout(app, 3)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if let s = value as? String { return s.isEmpty ? nil : s }
    return nil
}

func frame(_ element: AXUIElement) -> [Double]? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return [point.x, point.y, size.width, size.height].map { Double($0) }
}

var visited = 0
func node(_ element: AXUIElement, depth: Int) -> [String: Any] {
    visited += 1
    var out: [String: Any] = [:]
    let keys: [(String, String)] = [
        ("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("role_description", kAXRoleDescriptionAttribute),
        ("title", kAXTitleAttribute), ("label", kAXDescriptionAttribute), ("value", kAXValueAttribute),
        ("identifier", kAXIdentifierAttribute),
    ]
    for (key, name) in keys { if let s = string(element, name) { out[key] = s } }
    if let f = frame(element) { out["frame"] = f }
    if depth < maxDepth, visited < 40_000, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        out["children"] = children.map { node($0, depth: depth + 1) }
    }
    return out
}

let tree = node(app, depth: 0)
let data = try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
