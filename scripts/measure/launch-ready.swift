// One launch of a cmux NEXT app the way the Dock launches it (CMUX-629, CMUX-631), timed from outside the app.
//
//   launch-ready APP HOME_ROOT LABEL [SETTLE_S [SOCKET [shell] [layout]]]
//
// With `shell` (launch-ready.sh state=bare), once the app marks `window_usable` the probe opens a terminal the way a
// person's first one opens (`action.run newSurface` on the app's socket) and records `shell_requested`; the app's
// `first_shell_live` mark is that terminal's first shell output.
//
// With `layout` (launch-ready.sh layout=1), from the first on-screen frame the probe samples the first window's frame
// (CGWindowList, any build) every 16 ms and the sidebar's edge (the middle of `debug.layers`'
// sidebar_resize_area_in_window: a bench or DEBUG build) every 48 ms, until neither changed for 1 s or 3 s passed,
// and adds `layout` to the row: each one's first and last value, the most it moved from the first (points), how
// many times it changed after the first sample, and when it last changed (ms from process start).
//
// Opens APP through LaunchServices (NSWorkspace.openApplication: a new instance, activated, as a Dock click does)
// with a home under HOME_ROOT, and prints one `LR-RUN <json>` line. Times are ms from the app's process start
// (sysctl p_starttime), the clock the app's own launch marks use:
//   finished_launching  NSRunningApplication.isFinishedLaunching turned true: LaunchServices' "ready", sent once
//                       applicationDidFinishLaunching returns. The Dock's launch bounce lasts until then.
//   window_on_screen    the app's first on-screen window (CGWindowList: layer 0, alpha > 0, at least 200 pt wide)
//   active              NSRunningApplication.isActive turned true
//   request_to_start    the open request to the process start (LaunchServices' own part, before exec)
//   premain             the process's rusage read when its main_start mark arrives (a ms or two after main):
//                       user_ms and system_ms (CPU the process spent, the kernel's exec included), pageins and
//                       disk_read_kb. With main_start it splits the time before main: CPU, page-ins, or neither
//                       (the process existed but waited on something outside it).
// and `marks`: the app's launch marks (CMUX_NEXT_LAUNCH_MARKS_PATH, a FIFO read here), the ones every build has.
// After the window shows it waits SETTLE_S (default 6) and ends the app with SIGTERM ("Quit, keep sessions"), so
// the next launch with the same HOME_ROOT is a person's relaunch. An app that quits itself first (launch-ready.sh
// session=stress3's seed launch) ends the run then. Exit 0: a window showed; 1: none in 30 s.
// With HOME_ROOT/cmux-next.json (launch-ready.sh engines=) the app reads its settings from that file.
// SOCKET is the app's control socket (default HOME_ROOT/app.sock). A socket path must fit sun_path (104 bytes with
// its NUL); a fleet worker's checkout is deep enough that HOME_ROOT/app.sock does not, so launch-ready.sh passes a
// short one under /tmp.
import AppKit
import Darwin

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: launch-ready APP HOME_ROOT LABEL [SETTLE_S [SOCKET [shell] [layout]]]\n".utf8)); exit(2)
}
let appURL = URL(fileURLWithPath: args[1]), homeRoot = URL(fileURLWithPath: args[2]), label = args[3]
let settle = args.count > 4 ? Double(args[4]) ?? 6 : 6
let socketPath = args.count > 5 ? args[5] : homeRoot.appendingPathComponent("app.sock").path
guard socketPath.utf8.count <= 103 else { // sun_path less its NUL: the app could bind no socket there
    FileHandle.standardError.write(Data("launch-ready: socket path \(socketPath.utf8.count) bytes, over 103: \(socketPath)\n".utf8)); exit(2)
}
let flags = Set(args.dropFirst(6))
let opensShell = flags.contains("shell"), samplesLayout = flags.contains("layout")
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
// A side with its own settings (launch-ready.sh engines=): the app reads HOME_ROOT/cmux-next.json, not the account's.
let sideConfig = homeRoot.appendingPathComponent("cmux-next.json").path
if FileManager.default.fileExists(atPath: sideConfig) { environment["CMUX_NEXT_CONFIG_FILE"] = sideConfig }

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

// The app's on-screen windows that count as its window (layer 0, alpha > 0, at least 200 pt wide): number and frame.
func ownWindows(_ pid: pid_t) -> [(number: Int, frame: [Double])] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { info in
        guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
              ((info[kCGWindowAlpha as String] as? Double) ?? 0) > 0, let number = info[kCGWindowNumber as String] as? Int,
              let bounds = info[kCGWindowBounds as String] as? [String: Any], ((bounds["Width"] as? Double) ?? 0) >= 200 else { return nil }
        return (number, ["X", "Y", "Width", "Height"].map { (bounds[$0] as? Double) ?? 0 })
    }
}
func ownWindowOnScreen(_ pid: pid_t) -> Bool { !ownWindows(pid).isEmpty }

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

// One series of a layout value (a window frame, a sidebar edge) as the sampler saw it.
struct LayoutSeries {
    var first: [Double]?, last: [Double]?, moved = 0.0, changes = 0, firstAt: Double?, lastChangeAt: Double?
    mutating func add(_ value: [Double]?, at t: Double) -> Bool {
        guard let value else { return false }
        guard let first else { self.first = value; last = value; firstAt = t; return false }
        moved = max(moved, zip(value, first).map { abs($0 - $1) }.max() ?? 0)
        if value != last { changes += 1; lastChangeAt = t; last = value; return true }
        return false
    }
    func row(_ rel: (Double?) -> Any) -> [String: Any] {
        ["first": first ?? NSNull(), "last": last ?? NSNull(), "moved_pt": moved.rounded(toPlaces: 1), "changes": changes,
         "first_at": rel(firstAt), "last_change_at": rel(lastChangeAt)]
    }
}
// layout: from the first on-screen frame, on its own thread so the launch's timer keeps its 1 ms ticks.
var layoutWindow = LayoutSeries(), layoutSidebar = LayoutSeries(), layoutSamples = 0
let layoutDone = DispatchSemaphore(value: 0)
func sampleLayout(pid: pid_t, window number: Int, from seen: Double) {
    DispatchQueue.global(qos: .userInitiated).async {
        var quietSince = now(), tick = 0
        while now() - seen < 3000, now() - quietSince < 1000, kill(pid, 0) == 0 {
            let t = now()
            var changed = layoutWindow.add(ownWindows(pid).first { $0.number == number }?.frame, at: t)
            if tick % 3 == 0 {
                let windows = rpc("debug.layers")?["windows"] as? [[String: Any]] ?? []
                let own = windows.first { ($0["window_number"] as? Double).map(Int.init) == number } ?? windows.first
                if let area = own?["sidebar_resize_area_in_window"] as? [Double], area.count == 4 {
                    changed = layoutSidebar.add([(area[0] + area[2] / 2).rounded(toPlaces: 1)], at: t) || changed
                }
            }
            layoutSamples += 1
            tick += 1
            if changed { quietSince = t }
            usleep(16_000)
        }
        layoutDone.signal()
    }
}

// What is in front: the focused workspace (its model key, stable across launches), its tab and that tab's page
// ("home-dock" for the Home a launch docks in its workspace), the surface with the keyboard (`context.keys`
// surfaceKind; nil while the keyboard is on the sidebar or nowhere) and whether Home is in front: the focused tab is
// the docked Home, or Home covers the window (topPage "home", which a launch's docked Home never sets). Read once, after the
// settle and just before the quit, so nothing in the timed part of the launch waits on it. It is both what this
// launch reopened and what the next launch with this home must reopen (Leo, 2026-11-17: "my recently opened thing").
// snapshot.get is asked up to 3 times, 250 ms apart: one missed answer is not taken as nothing in front.
func front() -> [String: Any] {
    var topology: [String: Any]?
    for attempt in 0..<3 where topology == nil {
        if attempt > 0 { usleep(250_000) }
        topology = rpc("snapshot.get")?["topology"] as? [String: Any]
    }
    guard let topology else { return ["error": "snapshot.get did not answer 3 times"] }
    let focus = topology["focus"] as? [String: Any] ?? [:]
    let focused = focus["workspace"] as? String
    let workspace = (topology["workspaces"] as? [[String: Any]] ?? []).first { $0["id"] as? String == focused }?["key"] as? String ?? focused
    let context = rpc("context.keys") ?? [:]
    let keys = context["keys"] as? [String: Any] ?? context
    let surface = keys["surfaceKind"] as? String, page = (focus["tab"] as? String).flatMap { tabPage($0, in: topology) }
    return ["workspace": workspace.map { $0 as Any } ?? NSNull(), "tab": focus["tab"] ?? NSNull(), "page": page.map { $0 as Any } ?? NSNull(),
            "surface": surface.map { $0 as Any } ?? NSNull(),
            "home": keys["topPage"] as? String == "home" || page == "home-dock" || surface == "home-dock",
            "windows": (topology["windows"] as? [Any])?.count ?? 0]
}
var frontAtQuit: [String: Any]?

/// The `page` of the tab with id `tab` anywhere in snapshot.get's topology (its panes' tabs), nil if it names none.
func tabPage(_ tab: String, in node: Any) -> String? {
    if let object = node as? [String: Any] {
        if object["id"] as? String == tab, let page = object["page"] as? String { return page }
        for value in object.values { if let page = tabPage(tab, in: value) { return page } }
    } else if let array = node as? [Any] {
        for value in array { if let page = tabPage(tab, in: value) { return page } }
    }
    return nil
}

/// The process's CPU and pageins so far (proc_pid_rusage), CPU in ms; nil once it is gone.
func usage(_ pid: pid_t) -> [String: Any]? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return nil }
    var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
    func ms(_ ticks: UInt64) -> Double { (Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6).rounded(toPlaces: 1) }
    return ["user_ms": ms(info.ri_user_time), "system_ms": ms(info.ri_system_time), "pageins": Int(info.ri_pageins),
            "disk_read_kb": Int(info.ri_diskio_bytesread / 1024)]
}
var premain: [String: Any]?

let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
    let t = now()
    if app == nil {
        app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == appURL.standardizedFileURL.path && $0.processIdentifier > 0 && ($0.launchDate.map { $0.timeIntervalSince1970 * 1000 >= requested - 1000 } ?? true) }
    }
    guard let app else { if t - requested > 30_000 { failure = "no process in 30 s"; done = true }; return }
    let pid = app.processIdentifier
    if start == nil { start = processStart(pid) }
    if premain == nil, marks["main_start"] != nil { premain = usage(pid) }
    if finished == nil, app.isFinishedLaunching { finished = t }
    if active == nil, app.isActive { active = t }
    if window == nil, let first = ownWindows(pid).first {
        window = t; windowSeenAt = t
        if samplesLayout { sampleLayout(pid: pid, window: first.number, from: t) }
    }
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
let keep = ["stub_main", "main_start", "main.warmup_started", "main.environment", "main.state_folder", "main.reads_started", "main.crash_handlers",
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
    "premain": premain ?? NSNull(),
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
if samplesLayout, window != nil {
    let finished = layoutDone.wait(timeout: .now() + 5) == .success
    row["layout"] = ["window": layoutWindow.row(rel), "sidebar": layoutSidebar.row(rel), "samples": layoutSamples,
                     "complete": finished] as [String: Any]
}
if let failure { row["error"] = failure }
let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
print("LR-RUN", String(decoding: data, as: UTF8.self))
exit(window == nil ? 1 : 0)
