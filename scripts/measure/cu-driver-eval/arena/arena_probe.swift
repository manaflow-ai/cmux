// The arena's checker eyes (README.md): reads what an app shows through the accessibility tree, for
// tasks whose outcome lives only on screen (Calculator's display). The runner grants it Accessibility.
//
//   arena-probe ax-text BUNDLE_ID    every AXValue and AXTitle under the app's windows, one per line
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count == 3, args[1] == "ax-text" else {
  FileHandle.standardError.write("usage: arena-probe ax-text BUNDLE_ID\n".data(using: .utf8)!)
  exit(2)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[2]).first else {
  FileHandle.standardError.write("arena-probe: \(args[2]) is not running\n".data(using: .utf8)!)
  exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

var seen = 0
func walk(_ element: AXUIElement, depth: Int) {
  seen += 1
  guard depth < 40, seen < 5000 else { return }
  for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
    if let text = attribute(element, name as String) as? String, !text.isEmpty {
      print(text)
    }
  }
  if let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
    for child in children { walk(child, depth: depth + 1) }
  }
}

guard let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement] else {
  FileHandle.standardError.write("arena-probe: no windows (Accessibility granted?)\n".data(using: .utf8)!)
  exit(1)
}
for window in windows { walk(window, depth: 0) }
