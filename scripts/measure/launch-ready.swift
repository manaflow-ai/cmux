// One launch of a cmux NEXT app the way the Dock launches it (CMUX-629, CMUX-631), timed from outside the app.
//
//   launch-ready APP HOME_ROOT LABEL [SETTLE_S]
//
// Opens APP through LaunchServices (NSWorkspace.openApplication: a new instance, activated, as a Dock click does)
// with a home under HOME_ROOT, and prints one `LR-RUN <json>` line. Times are ms from the app's process start
// (sysctl p_starttime), the clock the app's own launch marks use:
//   finished_launching  NSRunningApplication.isFinishedLaunching turned true: LaunchServices' "ready", sent once
//                       applicationDidFinishLaunching returns. The Dock's launch bounce lasts until then.
//   window_on_screen    the app's first on-screen window (CGWindowList: layer 0, alpha > 0, at least 200 pt wide)
//   active              NSRunningApplication.isActive turned true
//   request_to_start    the open request to the process start (LaunchServices' own part, before exec)
// and `marks`: the app's launch marks (CMUX_NEXT_LAUNCH_MARKS_PATH, a FIFO read here), the ones every build has.
// After the window shows it waits SETTLE_S (default 6) and ends the app with SIGTERM ("Quit, keep sessions"), so
// the next launch with the same HOME_ROOT is a person's relaunch. An app that quits itself first (launch-ready.sh
// session=stress3's seed launch) ends the run then. Exit 0: a window showed; 1: none in 30 s.
import AppKit
import Darwin

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: launch-ready APP HOME_ROOT LABEL [SETTLE_S]\n".utf8)); exit(2)
}
let appURL = URL(fileURLWithPath: args[1]), homeRoot = URL(fileURLWithPath: args[2]), label = args[3]
let settle = args.count > 4 ? Double(args[4]) ?? 6 : 6
let home = homeRoot.appendingPathComponent("h"), tmp = homeRoot.appendingPathComponent("t")
for sub in ["Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs"] {
    try? FileManager.default.createDirectory(at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
}
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func now() -> Double { var tv = timeval(); gettimeofday(&tv, nil); return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000 }

func processStart(_ pid: pid_t) -> Double? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
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
configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]

let requested = now()
var app: NSRunningApplication?, start: Double?
var finished: Double?, window: Double?, active: Double?, windowSeenAt: Double?, quitSent: Double?
var done = false, failure: String?

NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { running, error in
    if let error { DispatchQueue.main.async { failure = "open: \(error.localizedDescription)"; done = true } }
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

let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
    let t = now()
    if app == nil {
        app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == appURL.standardizedFileURL.path && $0.processIdentifier > 0 && ($0.launchDate.map { $0.timeIntervalSince1970 * 1000 >= requested - 1000 } ?? true) }
    }
    guard let app else { if t - requested > 30_000 { failure = "no process in 30 s"; done = true }; return }
    let pid = app.processIdentifier
    if start == nil { start = processStart(pid) }
    if finished == nil, app.isFinishedLaunching { finished = t }
    if active == nil, app.isActive { active = t }
    if window == nil, ownWindowOnScreen(pid) { window = t; windowSeenAt = t }
    if let seen = windowSeenAt, quitSent == nil, t - seen >= settle * 1000 { quitSent = t; kill(pid, SIGTERM) }
    if window == nil, quitSent == nil, t - requested > 30_000 { failure = "no window in 30 s"; quitSent = t; kill(pid, SIGTERM) }
    if quitSent == nil, windowSeenAt != nil, app.isTerminated { quitSent = t }
    if let sent = quitSent {
        if app.isTerminated || kill(pid, 0) != 0 { done = true }
        else if t - sent > 30_000 { kill(pid, SIGKILL); done = true }
    }
}
RunLoop.main.add(timer, forMode: .common)
while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }

func rel(_ value: Double?) -> Any { guard let value, let start else { return NSNull() }; return (value - start * 1).rounded(toPlaces: 1) }
extension Double { func rounded(toPlaces places: Int) -> Double { let p = pow(10, Double(places)); return (self * p).rounded() / p } }
let keep = ["main_start", "main.warmup_started", "main.environment", "main.state_folder", "main.reads_started", "main.crash_handlers",
            "main.nsapp_made", "main.delegate_made", "main.nsapp", "main.run", "app.did_finish_launching_entry", "did_finish_launching_start",
            "dfl.settings_read", "dfl.theme", "services.crash_reporting", "dfl.services", "dfl.bind", "dfl.menu", "dfl.home_history",
            "launch_snapshot_shown", "first_window_flushed", "did_finish_launching_end", "first_window_frame_committed", "home.first_page", "reveal.home",
            "deferred_windows_restored"]
var row: [String: Any] = [
    "label": label, "pid": app?.processIdentifier ?? 0, "start_epoch_ms": start ?? NSNull(),
    "request_to_start": start.map { ($0 - requested).rounded(toPlaces: 1) } ?? NSNull(),
    "finished_launching": rel(finished), "window_on_screen": rel(window), "active": rel(active),
    // The prime launch (a fresh home: no Home cache, no Chief yet) keeps every mark, so the steps of its
    // wait for Home (home.chief_owner_ready, home.chief_create_replied, ...) can be named; every launch keeps
    // the launch steps (dfl.*), Home's (home.*) and every region the first window reveals (reveal.*): a launch that
    // opens on a pane, not Home, is timed by reveal.pane, so a relaunch's cache read and its first region show too.
    "marks": marks.filter { label == "prime" || keep.contains($0.key) || $0.key.hasPrefix("dfl.") || $0.key.hasPrefix("home.") || $0.key.hasPrefix("reveal.") },
    "all_marks": marks.count,
    // The region the window showed first (home, pane, ...): the region a person saw, whichever it is.
    "first_reveal": marks.filter { $0.key.hasPrefix("reveal.") }.min { $0.value < $1.value }.map { String($0.key.dropFirst("reveal.".count)) } ?? NSNull(),
]
if let failure { row["error"] = failure }
let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
print("LR-RUN", String(decoding: data, as: UTF8.self))
exit(window == nil ? 1 : 0)
