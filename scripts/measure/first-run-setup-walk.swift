// Accessibility text of one running app (by bundle id), for scripts/measure/first-run-setup-walk.sh.
//   frsw BUNDLE trusted        exit 0 when this process has the Accessibility grant
//   frsw BUNDLE text           every window's titles, values, descriptions and labels, one per line, then
//                              one `FRSW-COUNT read=N windows=W cut=0|1` line (cut: an element or depth bound hit)
//   frsw BUNDLE press L1 [L2..] AXPress the first AXButton titled (or described) L1, else L2, ...; prints the label
//                              pressed (exit 0), or exits 1 when no window names one
// Exit: 0 done, 2 usage, no grant or no app.
import AppKit
import ApplicationServices
import Foundation

let args = CommandLine.arguments
func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(2) }
guard args.count >= 3 else { fail("usage: frsw BUNDLE trusted|text|press LABEL...") }
let bundle = args[1], verb = args[2]
if verb == "trusted" { print(AXIsProcessTrusted() ? "trusted" : "untrusted"); exit(AXIsProcessTrusted() ? 0 : 2) }
guard AXIsProcessTrusted() else { fail("untrusted: no Accessibility grant") }
guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
    .max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else { fail("no running app \(bundle)") }
let app = AXUIElementCreateApplication(running.processIdentifier)
AXUIElementSetMessagingTimeout(app, 3.0)
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
var read = 0, cut = false
var seen = Set<String>()
func walk(_ e: AXUIElement, _ depth: Int) {
    if read >= 20000 || depth > 80 { cut = true; return }
    read += 1
    for n in ["AXTitle", "AXValue", "AXDescription", "AXLabel", "AXHelp", "AXPlaceholderValue"] {
        if let s = attr(e, n) as? String, !s.isEmpty, seen.insert(s).inserted { print(s.replacingOccurrences(of: "\n", with: " ")) }
    }
    for k in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(k, depth + 1) }
}
let wins = (attr(app, "AXWindows") as? [AXUIElement]) ?? []
// The first AXButton under E whose title or description is LABEL (bounded like walk).
func button(_ e: AXUIElement, _ label: String, _ depth: Int, _ budget: inout Int) -> AXUIElement? {
    if budget <= 0 || depth > 80 { return nil }
    budget -= 1
    if (attr(e, "AXRole") as? String) == "AXButton",
       [attr(e, "AXTitle") as? String, attr(e, "AXDescription") as? String].contains(label) { return e }
    for k in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] {
        if let hit = button(k, label, depth + 1, &budget) { return hit }
    }
    return nil
}
if verb == "press" {
    for label in args.dropFirst(3) {
        for w in wins {
            var budget = 20000
            if let b = button(w, label, 0, &budget), AXUIElementPerformAction(b, kAXPressAction as CFString) == .success {
                print(label); exit(0)
            }
        }
    }
    exit(1)
}
guard verb == "text" else { fail("usage: frsw BUNDLE trusted|text|press LABEL...") }
for w in wins { walk(w, 0) }
print("FRSW-COUNT read=\(read) windows=\(wins.count) cut=\(cut ? 1 : 0)")
