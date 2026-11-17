// One first launch of a freshly installed, quarantined app, the way a new user's double-click starts it (CMUX-629:
// "the whole point is a fresh launch somebody installing and launching from scratch"), timed from outside the app.
//
//   fresh-install-launch APP HOME_ROOT LABEL [SETTLE_S] [APPROVER]
//
// Opens APP through LaunchServices (NSWorkspace.openApplication, activated, as a Finder double-click or a Dock click
// does) with an empty home under HOME_ROOT, and prints one `FIL-RUN <json>` line. Every time is ms since the open
// request, the moment the person double-clicked:
//   prompt            Gatekeeper's first-launch dialog ("... downloaded from the Internet. Are you sure you want to
//                     open it?", a CoreServicesUIAgent window) is on screen: syspolicyd's assessment and the XProtect
//                     scan run before it shows
//   approved          the dialog's Open button was pressed (in this process through Accessibility when it is trusted,
//                     else by APPROVER, a command given the dialog's pid and window id) and the dialog is gone
//   exec              the app's process started (sysctl p_starttime)
//   finished_launching  NSRunningApplication.isFinishedLaunching turned true (the Dock's bounce ends)
//   window            the app's first on-screen window (CGWindowList: layer 0, alpha > 0, at least 200 pt wide)
//   settled           the first moment after the window from which every process running out of the bundle used under
//                     10% of one core for a whole second (QUIET_*): the first-run UI is up and idle
//   window_system, settled_system  the same minus the dialog's dwell (prompt to approved): the launch as if the
//                     person clicked Open the instant it showed
// and `marks`: the app's own launch marks (cmux NEXT's CMUX_NEXT_LAUNCH_MARKS_PATH FIFO; none for other apps), moved
// onto the request clock. pageins and cpu_ms add up every process that ran out of the bundle (proc_pid_rusage).
// SETTLE_S (default 3) after settling it sends the app SIGTERM. Exit 0: a window showed; 1: it did not.
import AppKit
import ApplicationServices
import Darwin

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: fresh-install-launch APP HOME_ROOT LABEL [SETTLE_S] [APPROVER]\n".utf8)); exit(2)
}
let appURL = URL(fileURLWithPath: args[1]).standardizedFileURL, homeRoot = URL(fileURLWithPath: args[2]), label = args[3]
let settleAfter = args.count > 4 ? Double(args[4]) ?? 3 : 3
let approver = args.count > 5 && !args[5].isEmpty ? args[5] : nil
let bundlePrefix = appURL.path + "/"
let home = homeRoot.appendingPathComponent("h"), tmp = homeRoot.appendingPathComponent("t")
for sub in ["Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs"] {
    try? FileManager.default.createDirectory(at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
}
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let QUIET_WINDOW_MS = 1000.0, QUIET_CPU_MS = 100.0, GIVE_UP_MS = 120_000.0

func now() -> Double { var tv = timeval(); gettimeofday(&tv, nil); return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000 }
extension Double { func r1() -> Double { (self * 10).rounded() / 10 } }

func processStart(_ pid: pid_t) -> Double? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
}

// Every process running out of the bundle, with its CPU time (ms) and page-ins. A process that exited is remembered
// with its last reading, so the totals keep what short-lived helpers used.
var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
var seenProcs: [pid_t: (cpu: Double, pageins: UInt64)] = [:]
func sampleBundle() -> Double {
    var pids = [pid_t](repeating: 0, count: 8192)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var path = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).hasPrefix(bundlePrefix) else { continue }
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { continue }
        let ticks = Double(info.ri_user_time + info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom)
        seenProcs[pid] = (ticks / 1_000_000, info.ri_pageins)
    }
    return seenProcs.values.reduce(0) { $0 + $1.cpu }
}

// The marks FIFO: open for reading first, so the app's nonblocking open for writing finds a reader.
let fifo = homeRoot.appendingPathComponent("marks.fifo").path
unlink(fifo); mkfifo(fifo, 0o600)
let fifoFD = open(fifo, O_RDONLY | O_NONBLOCK)
var marks: [String: Double] = [:], pending = Data()
let markSource = DispatchSource.makeReadSource(fileDescriptor: fifoFD, queue: .main)
markSource.setEventHandler {
    var buffer = [UInt8](repeating: 0, count: 65536)
    let count = read(fifoFD, &buffer, buffer.count)
    guard count > 0 else { return }
    pending.append(contentsOf: buffer[0..<count])
    while let newline = pending.firstIndex(of: 10) {
        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
        pending.removeSubrange(pending.startIndex...newline)
        let parts = line.split(separator: " ")
        if parts.count >= 2, let ms = Double(parts[parts.count - 1]) {
            let name = parts[0..<(parts.count - 1)].joined(separator: " ")
            if marks[name] == nil { marks[name] = ms }
        }
    }
}
markSource.resume()

var environment: [String: String] = [
    "HOME": home.path, "CFFIXED_USER_HOME": home.path, "TMPDIR": tmp.path + "/",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh",
    "CMUX_NEXT_SOCKET_PATH": homeRoot.appendingPathComponent("app.sock").path, "CMUX_NEXT_SOCKET_MODE": "allowAll",
    "CMUX_NEXT_LAUNCH_MARKS_PATH": fifo,
]
if let user = ProcessInfo.processInfo.environment["USER"] { environment["USER"] = user; environment["LOGNAME"] = user }

let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = true
configuration.addsToRecentItems = false
configuration.environment = environment

// Gatekeeper's dialog: an on-screen window of CoreServicesUIAgent (its owner name needs no Screen Recording grant).
func gatekeeperWindow() -> (pid: pid_t, id: Int)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list where (info[kCGWindowOwnerName as String] as? String) == "CoreServicesUIAgent" {
        if let pid = info[kCGWindowOwnerPID as String] as? Int32, let id = info[kCGWindowNumber as String] as? Int,
           ((info[kCGWindowAlpha as String] as? Double) ?? 0) > 0 { return (pid, id) }
    }
    return nil
}

// Presses the dialog's Open button through Accessibility (this process must be trusted). Returns the dialog's text.
func pressOpen(_ pid: pid_t) -> (pressed: Bool, text: String) {
    let root = AXUIElementCreateApplication(pid)
    var texts: [String] = [], pressed = false
    func walk(_ el: AXUIElement, _ depth: Int) {
        guard depth < 12, !pressed else { return }
        var role: CFTypeRef?, title: CFTypeRef?, value: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value)
        if let v = value as? String, !v.isEmpty { texts.append(v) }
        if (role as? String) == (kAXButtonRole as String), let t = title as? String, t == "Open" {
            pressed = AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
            return
        }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
        for kid in (kids as? [AXUIElement]) ?? [] { walk(kid, depth + 1) }
    }
    var windows: CFTypeRef?
    AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
    for w in (windows as? [AXUIElement]) ?? [] { walk(w, 0) }
    return (pressed, texts.joined(separator: " | "))
}

let requested = now()
var app: NSRunningApplication?, start: Double?
var prompt: Double?, approveStarted: Double?, approved: Double?, approveHow: String?, promptText: String?, promptCount = 0
var finished: Double?, window: Double?, active: Double?, settled: Double?, quitSent: Double?
var done = false, failure: String?, approving = false
var cpuHistory: [(t: Double, cpu: Double)] = [], lastSample = 0.0

NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { running, error in
    if let error { DispatchQueue.main.async { if app == nil { failure = "open: \(error.localizedDescription)" } } }
    if let running { DispatchQueue.main.async { if app == nil { app = running } } }
}

func ownWindowOnScreen(_ pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
    return list.contains { info in
        guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
              ((info[kCGWindowAlpha as String] as? Double) ?? 0) > 0,
              let bounds = info[kCGWindowBounds as String] as? [String: Any], ((bounds["Width"] as? Double) ?? 0) >= 200 else { return false }
        return true
    }
}

func approve(_ dialog: (pid: pid_t, id: Int)) {
    approving = true
    approveStarted = now()
    if AXIsProcessTrusted() {
        let (ok, text) = pressOpen(dialog.pid)
        promptText = text
        approveHow = ok ? "ax" : "ax-no-open-button"
        approving = false
        return
    }
    guard let approver else { approveHow = "none: not trusted for Accessibility and no APPROVER"; failure = approveHow; done = true; return }
    approveHow = "approver"
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [approver, String(dialog.pid), String(dialog.id)]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        DispatchQueue.main.async { promptText = String(out.suffix(600)); approving = false }
    }
}

let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
    let t = now()
    if t - requested > GIVE_UP_MS, quitSent == nil { failure = failure ?? "gave up after \(Int(GIVE_UP_MS / 1000)) s"; quitSent = t; if let app { kill(app.processIdentifier, SIGTERM) } else { done = true } }
    // The dialog: seen, pressed, gone. A second dialog (another prompt) is counted and pressed the same way.
    if approved == nil || prompt == nil {
        if let dialog = gatekeeperWindow() {
            if prompt == nil { prompt = t; promptCount += 1 }
            if !approving, approveStarted == nil || t - (approveStarted ?? t) > 3000 { approve(dialog) }
        } else if prompt != nil, approved == nil, !approving { approved = t }
    }
    if app == nil {
        app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == appURL.path && $0.processIdentifier > 0 }
    }
    guard let app else { return }
    let pid = app.processIdentifier
    if start == nil { start = processStart(pid) }
    if finished == nil, app.isFinishedLaunching { finished = t }
    if active == nil, app.isActive { active = t }
    if window == nil, ownWindowOnScreen(pid) { window = t }
    if t - lastSample >= 100 {
        lastSample = t
        cpuHistory.append((t, sampleBundle()))
        if let window, settled == nil {
            // the earliest sample at or after the window from which the next QUIET_WINDOW_MS used under QUIET_CPU_MS
            if let first = cpuHistory.lastIndex(where: { $0.t <= t - QUIET_WINDOW_MS }), cpuHistory[first].t >= window - 100,
               cpuHistory.last!.cpu - cpuHistory[first].cpu < QUIET_CPU_MS {
                settled = cpuHistory[first].t
            }
        }
    }
    if let settled, quitSent == nil, t - settled >= settleAfter * 1000 { quitSent = t; kill(pid, SIGTERM) }
    if quitSent == nil, window != nil, app.isTerminated { quitSent = t }
    if let sent = quitSent {
        if app.isTerminated || kill(pid, 0) != 0 { done = true }
        else if t - sent > 30_000 { kill(pid, SIGKILL); done = true }
    }
}
RunLoop.main.add(timer, forMode: .common)
while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

func rel(_ v: Double?) -> Any { v.map { ($0 - requested).r1() } ?? NSNull() }
let dwell = (prompt != nil && approved != nil) ? approved! - prompt! : 0
func sys(_ v: Double?) -> Any { v.map { ($0 - requested - dwell).r1() } ?? NSNull() }
var row: [String: Any] = [
    "label": label, "pid": app?.processIdentifier ?? 0, "request_epoch_ms": requested.r1(),
    "prompt": rel(prompt), "approve_started": rel(approveStarted), "approved": rel(approved), "approve_how": approveHow ?? NSNull(),
    "prompt_dwell": dwell.r1(), "prompt_count": promptCount, "prompt_text": promptText ?? NSNull(),
    "exec": rel(start), "finished_launching": rel(finished), "window": rel(window), "active": rel(active), "settled": rel(settled),
    "window_system": sys(window), "settled_system": sys(settled), "exec_system": sys(start),
    "pageins": seenProcs.values.reduce(UInt64(0)) { $0 + $1.pageins }, "cpu_ms": seenProcs.values.reduce(0) { $0 + $1.cpu }.r1(),
    "bundle_procs": seenProcs.count,
    "marks": start.map { s in marks.mapValues { ($0 + s - requested).r1() } } ?? [:],
]
if let failure { row["error"] = failure }
let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
print("FIL-RUN", String(decoding: data, as: UTF8.self))
exit(window == nil ? 1 : 0)
