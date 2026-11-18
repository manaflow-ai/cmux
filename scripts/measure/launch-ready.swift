// One launch of a cmux NEXT app the way the Dock launches it (CMUX-629, CMUX-631), timed from outside the app.
//
//   launch-ready APP HOME_ROOT LABEL [SETTLE_S [SOCKET [shell]]]
//
// With `shell` (launch-ready.sh state=bare), once the app marks `window_usable` the probe opens a terminal the way a
// person's first one opens (`action.run newSurface` on the app's socket) and records `shell_requested`; the app's
// `first_shell_live` mark is that terminal's first shell output.
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
// SOCKET is the app's control socket (default HOME_ROOT/app.sock). A socket path must fit sun_path (104 bytes with
// its NUL); a fleet worker's checkout is deep enough that HOME_ROOT/app.sock does not, so launch-ready.sh passes a
// short one under /tmp.
import AppKit
import Darwin

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: launch-ready APP HOME_ROOT LABEL [SETTLE_S [SOCKET [shell]]]\n".utf8)); exit(2)
}
let appURL = URL(fileURLWithPath: args[1]), homeRoot = URL(fileURLWithPath: args[2]), label = args[3]
let settle = args.count > 4 ? Double(args[4]) ?? 6 : 6
let socketPath = args.count > 5 ? args[5] : homeRoot.appendingPathComponent("app.sock").path
guard socketPath.utf8.count <= 103 else { // sun_path less its NUL: the app could bind no socket there
    FileHandle.standardError.write(Data("launch-ready: socket path \(socketPath.utf8.count) bytes, over 103: \(socketPath)\n".utf8)); exit(2)
}
let opensShell = args.count > 6 && args[6] == "shell"
var shellRequested: Double?
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
            if name == "window_usable", opensShell, shellRequested == nil { shellRequested = now(); requestShell() }
        }
    }
}
markSource.resume()

/// A person's first terminal: `action.run newSurface` on the app's socket, from a thread of its own (the reply waits
/// for the terminal). The reply only goes to stderr (probe.log).
func requestShell() {
    let path = socketPath
    Thread.detachNewThread {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes + [0])
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { FileHandle.standardError.write(Data("launch-ready: shell request: connect failed \(errno)\n".utf8)); return }
        let request = Data(#"{"id":1,"method":"action.run","params":{"action":"newSurface"}}"#.utf8 + [10])
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &buffer, buffer.count)
        if count > 0 { FileHandle.standardError.write(Data("launch-ready: shell request reply: ".utf8) + Data(buffer[0..<count])) }
    }
}

var environment: [String: String] = [
    "HOME": home.path, "CFFIXED_USER_HOME": home.path, "TMPDIR": tmp.path + "/",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh",
    "CMUX_NEXT_SOCKET_PATH": socketPath, "CMUX_NEXT_SOCKET_MODE": "allowAll",
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

// One request on the app's control socket (line JSON, release methods only): its result, or nil.
func rpc(_ method: String) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var limit = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { path in
        for (index, byte) in socketPath.utf8.enumerated() { path[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    let message: [String: Any] = ["id": 1, "method": method, "params": [String: Any]()]
    guard connected == 0, let body = try? JSONSerialization.data(withJSONObject: message) else { return nil }
    let request = body + Data("\n".utf8)
    guard request.withUnsafeBytes({ write(fd, $0.baseAddress, request.count) }) == request.count else { return nil }
    var reply = Data(), chunk = [UInt8](repeating: 0, count: 1 << 16)
    while !reply.contains(10) {
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count <= 0 { break }
        reply.append(contentsOf: chunk[0..<count])
    }
    guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any], object["ok"] as? Bool == true else { return nil }
    return object["result"] as? [String: Any]
}

// What is in front: the focused workspace (its model key, stable across launches), its tab, and the key window's top
// page (`context.keys` topPage: "home" when Home is in front; snapshot.get has no top page). Read once, after the
// settle and just before the quit, so nothing in the timed part of the launch waits on it. It is both what this
// launch reopened and what the next launch with this home must reopen (Leo, 2026-11-17: "my recently opened thing").
func front() -> [String: Any] {
    guard let snapshot = rpc("snapshot.get"), let topology = snapshot["topology"] as? [String: Any] else {
        return ["error": "snapshot.get did not answer"]
    }
    let focus = topology["focus"] as? [String: Any] ?? [:]
    let focused = focus["workspace"] as? String
    let workspace = (topology["workspaces"] as? [[String: Any]] ?? []).first { $0["id"] as? String == focused }?["key"] as? String ?? focused
    let context = rpc("context.keys") ?? [:]
    let keys = context["keys"] as? [String: Any] ?? context
    return ["workspace": workspace.map { $0 as Any } ?? NSNull(), "tab": focus["tab"] ?? NSNull(), "top_page": keys["topPage"] ?? NSNull(),
            "windows": (topology["windows"] as? [Any])?.count ?? 0]
}
var frontAtQuit: [String: Any]?

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
    if let seen = windowSeenAt, quitSent == nil, t - seen >= settle * 1000 { frontAtQuit = front(); quitSent = now(); kill(pid, SIGTERM) }
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
            "deferred_windows_restored",
            // The bare launch's marks (piece 8): Home's composer takes keys; a terminal's shell printed its first output.
            "window_usable", "first_shell_live"]
var row: [String: Any] = [
    "label": label, "pid": app?.processIdentifier ?? 0, "start_epoch_ms": start ?? NSNull(),
    "request_to_start": start.map { ($0 - requested).rounded(toPlaces: 1) } ?? NSNull(),
    "finished_launching": rel(finished), "window_on_screen": rel(window), "active": rel(active),
    // The prime launch (a fresh home: no Home cache, no Chief yet) keeps every mark, so the steps of its
    // wait for Home (home.chief_owner_ready, home.chief_create_replied, ...) can be named; every launch keeps
    // the launch steps (dfl.*), Home's (home.*) and every region the first window reveals (reveal.*): a launch that
    // opens on a pane, not Home, is timed by reveal.pane, so a relaunch's cache read and its first region show too.
    // It also keeps what the first window waits on before it shows: the bundled CLI's `cloud env get`
    // (cloud_env.*), the app delegate's steps (app.*), the daemon's snapshot read (daemon.*) and the launch
    // snapshot's own steps (launch_snapshot*). Only the prime launch had them, so a relaunch could not say how long
    // its window still waited on the CLI (2026-11-17: 635 ms on a fresh home's prime launch, and no relaunch row).
    "marks": marks.filter { mark in
        label == "prime" || keep.contains(mark.key)
            || ["dfl.", "home.", "reveal.", "cloud_env.", "app.", "daemon.", "launch_snapshot"].contains { mark.key.hasPrefix($0) }
    },
    "all_marks": marks.count,
    "shell_requested": rel(shellRequested),
    // The region the window showed first (home, pane, ...): the region a person saw, whichever it is.
    "first_reveal": marks.filter { $0.key.hasPrefix("reveal.") }.min { $0.value < $1.value }.map { String($0.key.dropFirst("reveal.".count)) } ?? NSNull(),
]
if let frontAtQuit { row["front"] = frontAtQuit }
if let failure { row["error"] = failure }
let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
print("LR-RUN", String(decoding: data, as: UTF8.self))
exit(window == nil ? 1 : 0)
