// rivals-ax: when does an app become interactive, generically, through Accessibility.
//
//   rivals-ax PID TIMEOUT_S
//
// Polls the app's AX tree (5 ms) and prints one JSON line:
//   {"trusted":bool,"window_ms":epoch|null,"field_ms":epoch|null,"role":"AXTextArea"|null}
// window_ms: first poll where the app has an AXWindow. field_ms: first poll where the app's focused
// UI element is a text input (AXTextField, AXTextArea, AXComboBox, AXSearchField) inside a window,
// the moment a composer (or a sign-in field) accepts typing. Electron/Chromium apps build their AX
// tree only when asked, so AXManualAccessibility and AXEnhancedUserInterface are set on the app.
// Needs the Accessibility grant of whichever process runs this; without it "trusted" is false and
// both times are null. Epoch ms, the same clock as benchhelper wait-window and the driver's t0.
import ApplicationServices
import Foundation

func epochMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func emit(_ trusted: Bool, _ window: Double?, _ field: Double?, _ role: String?) -> Never {
    func num(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "null" }
    print("{\"trusted\":\(trusted),\"window_ms\":\(num(window)),\"field_ms\":\(num(field)),\"role\":\(role.map { "\"\($0)\"" } ?? "null")}")
    exit(0)
}

let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[1]), let timeout = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: rivals-ax PID TIMEOUT_S\n".utf8))
    exit(2)
}
guard AXIsProcessTrusted() else { emit(false, nil, nil, nil) }

let app = AXUIElementCreateApplication(pid)
AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
var windowAt: Double?
let deadline = Date().addingTimeInterval(timeout)
while Date() < deadline {
    let now = epochMs()
    if windowAt == nil, let windows = attr(app, kAXWindowsAttribute as String) as? [AnyObject], !windows.isEmpty {
        windowAt = now
    }
    if windowAt != nil, let focused = attr(app, kAXFocusedUIElementAttribute as String) {
        let element = focused as! AXUIElement
        if let role = attr(element, kAXRoleAttribute as String) as? String, textRoles.contains(role) {
            emit(true, windowAt, now, role)
        }
    }
    usleep(5000)
}
emit(true, windowAt, nil, nil)
