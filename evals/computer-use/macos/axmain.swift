// SPDX-License-Identifier: MIT
// axmain PID TITLE_PREFIX : make the app's window titled TITLE_PREFIX its main window through AX, without
// activating the app (the Codex arm: Codex Computer Use acts on an app's key window only). Prints
// {"changed": bool, "was": "<previous main window title>"}.
import AppKit
import ApplicationServices
let args = CommandLine.arguments
let pid = pid_t(Int32(args[1])!)
let prefix = args[2]
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
var was = ""
if let m = attr(app, "AXMainWindow") { was = (attr(m as! AXUIElement, "AXTitle") as? String) ?? "" }
var changed = false
if !was.hasPrefix(prefix) || (prefix.isEmpty && !was.isEmpty) {
    for w in (attr(app, "AXWindows") as? [AXUIElement]) ?? [] where ((attr(w, "AXTitle") as? String) ?? "").hasPrefix(prefix) {
        AXUIElementSetAttributeValue(w, "AXMain" as CFString, kCFBooleanTrue)
        changed = true; break
    }
}
let d = try! JSONSerialization.data(withJSONObject: ["changed": changed, "was": was])
print(String(data: d, encoding: .utf8)!)
