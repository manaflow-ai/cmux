// SPDX-License-Identifier: MIT
// probe: an independent observer for the background matrix (runs in the guest).
//   probe state            -> front app, its focused (key) window, pointer, on-screen window z-order
//   probe ax PID [DEPTH]   -> the app's AX tree (role, title, value, description, identifier,
//                             selected text range, focused, frame), windows first, JSON
import AppKit
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func str(_ v: AnyObject?) -> Any? {
    guard let v = v else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n }
    if CFGetTypeID(v) == AXValueGetTypeID() {
        let ax = v as! AXValue
        switch AXValueGetType(ax) {
        case .cfRange:
            var r = CFRange(); AXValueGetValue(ax, .cfRange, &r); return ["loc": r.location, "len": r.length]
        case .cgPoint:
            var p = CGPoint.zero; AXValueGetValue(ax, .cgPoint, &p); return ["x": p.x, "y": p.y]
        case .cgSize:
            var s = CGSize.zero; AXValueGetValue(ax, .cgSize, &s); return ["w": s.width, "h": s.height]
        default: return nil
        }
    }
    if let u = v as? URL { return u.absoluteString }
    return nil
}

var budget = 6000
func node(_ e: AXUIElement, depth: Int) -> [String: Any] {
    budget -= 1
    var d: [String: Any] = [:]
    for (k, a) in [("role", "AXRole"), ("subrole", "AXSubrole"), ("title", "AXTitle"), ("value", "AXValue"),
                   ("desc", "AXDescription"), ("id", "AXIdentifier"), ("sel", "AXSelectedTextRange"),
                   ("focused", "AXFocused"), ("pos", "AXPosition"), ("size", "AXSize"), ("enabled", "AXEnabled"),
                   ("selected", "AXSelected"), ("main", "AXMain"), ("doc", "AXDocument"), ("help", "AXHelp"),
                   ("placeholder", "AXPlaceholderValue")] {
        if let v = str(attr(e, a)) {
            if let s = v as? String {
                if k == "value" { d["vlen"] = (s as NSString).length }
                d[k] = s.count > 20000 ? String(s.prefix(20000)) : s
            } else { d[k] = v }
        }
    }
    if let rows = attr(e, "AXSelectedRows") as? [AXUIElement] {
        d["selected_rows"] = rows.count
        func label(_ r: AXUIElement, _ depth: Int) -> String? {
            if let v = attr(r, "AXValue") as? String, !v.isEmpty { return v }
            if depth > 0, let kids = attr(r, "AXChildren") as? [AXUIElement] { for k in kids { if let l = label(k, depth - 1) { return l } } }
            return nil
        }
        d["selected_names"] = rows.prefix(50).compactMap { label($0, 4) }
    }
    if depth > 0 && budget > 0, let kids = attr(e, "AXChildren") as? [AXUIElement] {
        let c = kids.prefix(400).map { node($0, depth: depth - 1) }
        if !c.isEmpty { d["children"] = c }
    }
    return d
}

func out(_ o: Any) {
    let data = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

let args = CommandLine.arguments
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 3)
switch args.count > 1 ? args[1] : "" {
case "state":
    var o: [String: Any] = ["trusted": AXIsProcessTrusted()]
    let p = CGEvent(source: nil)!.location
    o["pointer"] = ["x": p.x, "y": p.y]
    // The front app as the window server sees it (the first normal-layer window's owner) and LaunchServices.
    let wins = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    var z: [[String: Any]] = []
    for w in wins where (w[kCGWindowLayer as String] as? Int) == 0 {
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        z.append(["id": w[kCGWindowNumber as String] ?? 0, "pid": w[kCGWindowOwnerPID as String] ?? 0,
                  "owner": w[kCGWindowOwnerName as String] ?? "", "name": w[kCGWindowName as String] ?? "",
                  "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0])
    }
    o["zorder"] = z
    if let front = NSWorkspace.shared.frontmostApplication {
        o["front_pid"] = Int(front.processIdentifier); o["front_name"] = front.localizedName ?? ""
        let app = AXUIElementCreateApplication(front.processIdentifier)
        if let fw = attr(app, "AXFocusedWindow") {
            let w = fw as! AXUIElement
            o["key_window_title"] = (attr(w, "AXTitle") as? String) ?? ""
            if let pos = str(attr(w, "AXPosition")) { o["key_window_pos"] = pos }
        }
        if let fe = attr(app, "AXFocusedUIElement") {
            let e = fe as! AXUIElement
            o["focused_role"] = (attr(e, "AXRole") as? String) ?? ""
        }
    }
    out(o)
case "ax":
    let pid = pid_t(Int32(args[2])!)
    let depth = args.count > 3 ? Int(args[3])! : 30
    let app = AXUIElementCreateApplication(pid)
    var o: [String: Any] = [:]
    let wins = (attr(app, "AXWindows") as? [AXUIElement]) ?? []
    o["windows"] = wins.map { node($0, depth: depth) }
    if let fw = attr(app, "AXFocusedWindow") { o["focused_window_title"] = (attr(fw as! AXUIElement, "AXTitle") as? String) ?? "" }
    if let mb = attr(app, "AXMenuBar"), args.contains("menus") { o["menubar"] = node(mb as! AXUIElement, depth: 4) }
    out(o)
case "activate":
    // Test setup only: make the simulated person's app frontmost (the guest is a disposable VM).
    let pid = pid_t(Int32(args[2])!)
    let ok = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) ?? false
    out(["ok": ok])
case "watch":
    // Sample front app, its key window and the pointer every N ms; print a line on every change.
    let ms = args.count > 2 ? Int(args[2])! : 15
    setvbuf(stdout, nil, _IOLBF, 0)
    var last = ""
    let t0 = Date()
    while true {
        let p = CGEvent(source: nil)!.location
        var fp: Int32 = 0; var kt = ""
        // NSWorkspace's frontmostApplication is cached per run loop turn; ask LaunchServices through the window list instead:
        // the first layer-0 on-screen window's owner is the active app's front window only when it is key, so read both.
        if let front = NSWorkspace.shared.frontmostApplication { fp = front.processIdentifier }
        let app = AXUIElementCreateApplication(fp)
        if let fw = attr(app, "AXFocusedWindow") { kt = (attr(fw as! AXUIElement, "AXTitle") as? String) ?? "" }
        let wins = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let top = wins.first { ($0[kCGWindowLayer as String] as? Int) == 0 }
        let topId = top?[kCGWindowNumber as String] as? Int ?? 0
        let cur = "\(fp)|\(kt)|\(Int(p.x)),\(Int(p.y))|\(topId)"
        if cur != last {
            last = cur
            print("{\"t\":\(String(format: "%.3f", Date().timeIntervalSince(t0))),\"front_pid\":\(fp),\"key\":\"\(kt.replacingOccurrences(of: "\"", with: "'"))\",\"ptr\":[\(Int(p.x)),\(Int(p.y))],\"top_window\":\(topId)}")
            fflush(stdout)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(Double(ms) / 1000))
    }
case "frame":
    // Test setup only: move and size an app's window (by title prefix) with AX.
    let app = AXUIElementCreateApplication(pid_t(Int32(args[2])!))
    let wins = (attr(app, "AXWindows") as? [AXUIElement]) ?? []
    var done = false
    for w in wins where ((attr(w, "AXTitle") as? String) ?? "").hasPrefix(args[3]) {
        var pt = CGPoint(x: Double(args[4])!, y: Double(args[5])!)
        var sz = CGSize(width: Double(args[6])!, height: Double(args[7])!)
        AXUIElementSetAttributeValue(w, "AXPosition" as CFString, AXValueCreate(.cgPoint, &pt)!)
        if sz.width > 0 { AXUIElementSetAttributeValue(w, "AXSize" as CFString, AXValueCreate(.cgSize, &sz)!) }
        done = true; break
    }
    out(["ok": done])
case "close":
    // Test setup only: close an app's windows whose title starts with args[3] (AXCloseButton press).
    let app = AXUIElementCreateApplication(pid_t(Int32(args[2])!))
    var n = 0
    for w in (attr(app, "AXWindows") as? [AXUIElement]) ?? [] where ((attr(w, "AXTitle") as? String) ?? "").hasPrefix(args[3]) {
        if let b = attr(w, "AXCloseButton") { AXUIElementPerformAction(b as! AXUIElement, "AXPress" as CFString); n += 1 }
    }
    out(["closed": n])
case "raise":
    // Test setup only (foreground cells): make app args[2] frontmost and its window titled args[3] (prefix) key.
    let pid = pid_t(Int32(args[2])!)
    _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    let app = AXUIElementCreateApplication(pid)
    var raised = false
    for w in (attr(app, "AXWindows") as? [AXUIElement]) ?? [] where ((attr(w, "AXTitle") as? String) ?? "").hasPrefix(args[3]) {
        AXUIElementPerformAction(w, "AXRaise" as CFString)
        AXUIElementSetAttributeValue(w, "AXMain" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue)
        raised = true; break
    }
    out(["ok": raised])
case "hide":
    // Test setup only: hide an app (the cmux app's own window, so it covers nothing).
    out(["ok": NSRunningApplication(processIdentifier: pid_t(Int32(args[2])!))?.hide() ?? false])
case "press":
    // Test setup only: AXPress the first button titled args[3] in app args[2] (system alerts).
    let app = AXUIElementCreateApplication(pid_t(Int32(args[2])!))
    func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
        if (attr(e, "AXRole") as? String) == "AXButton" && (attr(e, "AXTitle") as? String) == args[3] { return e }
        guard d > 0, let kids = attr(e, "AXChildren") as? [AXUIElement] else { return nil }
        for k in kids { if let f = find(k, d - 1) { return f } }
        return nil
    }
    if let b = find(app, 12) { out(["ok": AXUIElementPerformAction(b, "AXPress" as CFString) == .success]) } else { out(["ok": false, "err": "not found"]) }
default:
    FileHandle.standardError.write("usage: probe state | probe ax PID [DEPTH] [menus]\n".data(using: .utf8)!)
    exit(2)
}
