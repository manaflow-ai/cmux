// One launch of a cmux NEXT app the way the Dock launches it (CMUX-629, CMUX-631), timed from outside the app.
//
//   launch-ready APP HOME_ROOT LABEL [SETTLE_S [SOCKET [MODES...]]]   MODES: shell, keys, layout, movequit, type, guest,
//                                                                      plain
//                                                                      (separate or comma-separated)
//
// With `guest` (launch-ready.sh guest=1, a run on a person's own Mac while they work) the app opens without
// activating and with CMUX_NEXT_NO_ACTIVATE=1, so the app never activates itself either: no focus is taken from what
// they are typing into, its windows open behind theirs, and `active` stays null.
//
// With `shell` (launch-ready.sh state=bare), once the app marks `window_usable` the probe opens a terminal the way a
// person's first one opens (`action.run newSurface` on the app's socket) and records `shell_requested`; the app's
// `first_shell_live` mark is that terminal's first shell output.
//
// With `type` (launch-ready.sh type=1) the app types one space and one Delete the moment its first window frame is in
// and a window is key (CMUX_NEXT_LAUNCH_TYPE_PROBE=1): `terminal.probe_key_typed`, then `terminal_input_accepted` (the
// key left the app for the restored terminal's PTY) and `terminal_echo` (the shell's echo came back).
//
// With `keys` (launch-ready.sh keys=1) it opens no terminal (that moves focus). From the moment it sees the window it
// posts one key every 100 ms to the app's pid (CGEvent postToPid: the app's own event queue, which AppKit hands to its
// key window's first responder), each the next of a-z then 0-9 (36 at most). Once Home's first page is up and the
// window took keys (home.first_page and window_usable) it posts 3 more and then Return, so Home's box sends; with no
// such marks it stops at 36 and presses Return at SETTLE_S less 1.5 s. Just before the quit it reads the sent message
// back from the app's daemon (sentText) and records first_key_ms (when the earliest key the message holds went out),
// keys_sent, keys_landed (how many of the sent keys the message holds) and keys_text.
//
// With `layout` (launch-ready.sh layout=1), from the first on-screen frame the probe samples the first window's frame
// (CGWindowList, any build) every 16 ms on one thread and the sidebar's edge (the middle of `debug.layers`'
// sidebar_resize_area_in_window: a bench or DEBUG build) as often as the app answers on another, until neither changed
// for 1 s or 3 s passed (the sidebar's first answer can come after the first frame: its first_at says when),
// and adds `layout` to the row: each one's first and last value, the most it moved from the first (points), how
// many times it changed after the first sample, and when it last changed (ms from process start).
// With `movequit` (launch-ready.sh layout=movequit, a DEBUG build), just before the quit the probe sets the window to the
// other of two frames (`debug.window_frame`: one setFrame, as an Accessibility client resizes) and the sidebar to the
// other of two widths (`debug.update_surfaces sidebar-width`), then quits at once, so the next launch starts from a
// record the launch snapshot may not have caught up with; the row's `movequit` says what was set and the ms to the quit.
//
// With `plain` (launch-ready.sh other=, any app that is not cmux) the probe gives the app no cmux variables and reads
// no front from a control socket at the quit: the row has the times read from outside (process start, finished
// launching, the first on-screen window, active) and `plain: true`.
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
    FileHandle.standardError.write(Data("usage: launch-ready APP HOME_ROOT LABEL [SETTLE_S [SOCKET [MODES...]]]\n".utf8)); exit(2)
}
let appURL = URL(fileURLWithPath: args[1]), homeRoot = URL(fileURLWithPath: args[2]), label = args[3]
let settle = args.count > 4 ? Double(args[4]) ?? 6 : 6
let socketPath = args.count > 5 ? args[5] : homeRoot.appendingPathComponent("app.sock").path
guard socketPath.utf8.count <= 103 else { // sun_path less its NUL: the app could bind no socket there
    FileHandle.standardError.write(Data("launch-ready: socket path \(socketPath.utf8.count) bytes, over 103: \(socketPath)\n".utf8)); exit(2)
}
let modes = Set(args.dropFirst(6).flatMap { $0.split(separator: ",").map(String.init) })
let opensShell = modes.contains("shell"), typesKeys = modes.contains("keys"), samplesLayout = modes.contains("layout")
let typesFirstKey = modes.contains("type"), movesBeforeQuit = modes.contains("movequit"), plainApp = modes.contains("plain")
let activates = !modes.contains("guest")
// record (launch-ready.sh record=1): the app records every window from its first frame (`--record-launch`, a Debug or
// bench build's DebugWindowRecord) into HOME_ROOT/record-LABEL, for the row's PERCEIVED numbers (launch_shift.py);
// the recording ends a second before the settle's quit, so its frames.json is written first.
let recordDir: String? = modes.contains("record") ? homeRoot.appendingPathComponent("record-\(label)").path : nil
if let recordDir { try? FileManager.default.removeItem(atPath: recordDir) }
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
// `type` (launch-ready.sh type=1): the app types one key at its first frame (LaunchTypeProbe) and marks its echo.
if typesFirstKey { environment["CMUX_NEXT_LAUNCH_TYPE_PROBE"] = "1" }
// `plain`: an app that is not cmux gets only the home, the temp folder and the shell basics.
if plainApp { environment = environment.filter { !$0.key.hasPrefix("CMUX_") } }
if let user = ProcessInfo.processInfo.environment["USER"] { environment["USER"] = user; environment["LOGNAME"] = user }
// A side with its own settings (launch-ready.sh engines=): the app reads HOME_ROOT/cmux-next.json, not the account's.
let sideConfig = homeRoot.appendingPathComponent("cmux-next.json").path
if FileManager.default.fileExists(atPath: sideConfig) { environment["CMUX_NEXT_CONFIG_FILE"] = sideConfig }
// guest: the app itself never activates either (AppEnvironment.noActivate, CmuxApplication.refusesActivation): every
// activation request is dropped and its windows open ordered back, still on screen for window_on_screen.
if !activates { environment["CMUX_NEXT_NO_ACTIVATE"] = "1" }

let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.activates = activates
configuration.addsToRecentItems = false
configuration.environment = environment
configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
    + (recordDir.map { ["--record-launch", $0, "--record-launch-seconds", String(max(1, min(12, settle - 1)))] } ?? [])

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
func rpc(_ method: String, _ params: [String: Any] = [:]) -> [String: Any]? {
    guard let object = lineRequest(socketPath, ["id": 1, "method": method, "params": params]),
          object["ok"] as? Bool == true else { return nil }
    return object["result"] as? [String: Any]
}

// One JSON line to the Unix socket at `path` and the first line back, parsed (nil: no connection or no JSON reply).
func lineRequest(_ path: String, _ message: [String: Any]) -> [String: Any]? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var limit = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
        for (index, byte) in path.utf8.prefix(sunPath.count - 1).enumerated() { sunPath[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0, let body = try? JSONSerialization.data(withJSONObject: message) else { return nil }
    let request = body + Data("\n".utf8)
    guard request.withUnsafeBytes({ write(fd, $0.baseAddress, request.count) }) == request.count else { return nil }
    var reply = Data(), chunk = [UInt8](repeating: 0, count: 1 << 16)
    while !reply.contains(10) {
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count <= 0 { break }
        reply.append(contentsOf: chunk[0..<count])
    }
    return try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
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
// layout: from the first on-screen frame, the window on one thread (CGWindowList only, so 16 ms apart) and the sidebar
// on another (each read waits on the app's socket), so neither slows the other or the launch's 1 ms timer.
var layoutWindow = LayoutSeries(), layoutSidebar = LayoutSeries(), layoutSamples = 0, sidebarSamples = 0
let layoutLock = NSLock(), layoutDone = DispatchGroup()
var layoutQuietSince = 0.0
func layoutChanged(_ t: Double) { layoutLock.lock(); layoutQuietSince = t; layoutLock.unlock() }
func layoutGoing(pid: pid_t, from seen: Double) -> Bool {
    layoutLock.lock(); defer { layoutLock.unlock() }
    return now() - seen < 3000 && now() - layoutQuietSince < 1000 && kill(pid, 0) == 0
}
func sampleLayout(pid: pid_t, window number: Int, from seen: Double) {
    layoutQuietSince = now()
    layoutDone.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        while layoutGoing(pid: pid, from: seen) {
            let t = now()
            if layoutWindow.add(ownWindows(pid).first { $0.number == number }?.frame, at: t) { layoutChanged(t) }
            layoutSamples += 1
            usleep(16_000)
        }
        layoutDone.leave()
    }
    layoutDone.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        while layoutGoing(pid: pid, from: seen) {
            let windows = rpc("debug.layers")?["windows"] as? [[String: Any]] ?? []
            let own = windows.first { ($0["window_number"] as? Double).map(Int.init) == number } ?? windows.first
            if let area = own?["sidebar_resize_area_in_window"] as? [Double], area.count == 4 {
                let t = now()
                if layoutSidebar.add([(area[0] + area[2] / 2).rounded(toPlaces: 1)], at: t) { layoutChanged(t) }
            }
            sidebarSamples += 1
            usleep(16_000)
        }
        layoutDone.leave()
    }
}

// movequit: what was set just before the quit and how long before it.
var moveQuit: [String: Any]?
func moveThenQuit(_ pid: pid_t) {
    // Which of the two the last launch of this home set (a file in the home root), so each quit changes both.
    let marker = homeRoot.appendingPathComponent("movequit.next")
    let index = (try? String(contentsOf: marker, encoding: .utf8)) == "1" ? 1 : 0
    let frames: [[Double]] = [[410, 92, 1100, 720], [300, 80, 1300, 800]], widths: [Double] = [260, 320]
    let frame = rpc("debug.window_frame", ["frame": frames[index]])
    let sidebar = rpc("debug.update_surfaces", ["action": "sidebar-width", "width": widths[index]])
    let changed = now()
    try? (index == 1 ? "0" : "1").write(to: marker, atomically: true, encoding: .utf8)
    quitSent = now()
    kill(pid, SIGTERM)
    moveQuit = ["frame": frames[index], "frame_set": frame?["frame"] ?? NSNull(), "sidebar_width": widths[index],
                "sidebar_previous": sidebar?["previous"] ?? NSNull(), "ms_to_quit": (quitSent! - changed).rounded(toPlaces: 1)]
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

// keys=1: the sequence (a-z then 0-9: 36 steps at most) and each character's ANSI key code (a US layout's; the event
// carries the character too, so another layout types the same text); when each step's key went out (now()), how many
// went out while the app was frontmost, the step typing stops at once Home is up, and when Return went out.
let keySequence = Array("abcdefghijklmnopqrstuvwxyz0123456789")
let keyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]
let returnKeyCode: CGKeyCode = 36
var keyPosts: [Double] = [], keysFront = 0, keysStopAt: Int?, returnSent: Double?, keysRead: [String: Any]?
// Whether this process may post events (Accessibility / PostEvent): without it postToPid drops them silently. Only
// read: a request would put a prompt on the console.
let keysAccess = typesKeys && CGPreflightPostEventAccess()
// With no Home marks, Return goes at SETTLE_S less 1.5 s (and after the 36th key), so the send reaches the daemon
// before the read back at the settle end.
let returnBy = max(settle * 1000 - 1500, Double(keySequence.count + 1) * 100)

/// One key, down and up, into the app's event queue.
func postKey(_ code: CGKeyCode, _ text: String, to pid: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
        event.postToPid(pid)
    }
}

/// The text of the message Home's box sent this launch, read from the app's daemon: cmux-tui keeps Home's
/// conversations, and the app's control socket has no release method that reads one (debug.home and
/// debug.home.delivery are in DEBUG and bench builds only). The daemon is the app's home session (snapshot.get's
/// topology.sessions, `session_name`) on the socket its owner listens on: the app starts it with TMPDIR set to the
/// user's Darwin temp folder and no XDG_RUNTIME_DIR (DaemonLauncher.userTemporaryDirectory), so
/// TEMP/cmux-tui-UID/SESSION.sock, or /tmp/cmux-tui-UID/SESSION.sock when that is too long for sun_path (cmux-tui-core
/// server/socket_path.rs). Read with `conversation-list` (each conversation's last message) and
/// `conversation-snapshot` (its last 20). The message is the newest created since `since` less 2 s whose text is only
/// sent keys' characters, in sent order (a relaunch's home also holds the earlier launches' messages).
func sentText(since: Double, sent: [Character]) -> [String: Any] {
    let sessions = (rpc("snapshot.get")?["topology"] as? [String: Any])?["sessions"] as? [[String: Any]] ?? []
    let session = sessions.first { $0["home"] as? Bool == true }?["session_name"] as? String ?? "cmux-app"
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let temp = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 ? String(cString: buffer) : "/tmp/"
    let leaf = "cmux-tui-\(getuid())/\(session).sock"
    let candidates = [URL(fileURLWithPath: temp).appendingPathComponent(leaf).path, "/tmp/" + leaf].filter { $0.utf8.count <= 103 }
    var daemon: String?, conversations: [[String: Any]] = []
    for path in candidates {
        if let reply = lineRequest(path, ["id": 1, "cmd": "conversation-list"]), reply["ok"] as? Bool == true {
            daemon = path
            conversations = (reply["data"] as? [String: Any])?["conversations"] as? [[String: Any]] ?? []
            break
        }
    }
    guard let daemon else { return ["read_error": "no daemon answered conversation-list", "session": session, "tried": candidates] }
    var found: [[String: Any]] = []
    for conversation in conversations {
        collectMessages(conversation, into: &found)
        if let id = conversation["id"] as? String,
           let reply = lineRequest(daemon, ["id": 2, "cmd": "conversation-snapshot", "conversation": id, "tail": 20]) {
            collectMessages(reply["data"] ?? NSNull(), into: &found)
        }
    }
    let optionSets: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
    let formats = optionSets.map { (options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter in
        let format = ISO8601DateFormatter()
        format.formatOptions = options
        return format
    }
    func createdMs(_ message: [String: Any]) -> Double? {
        guard let text = message["created_at"] as? String else { return nil }
        for format in formats { if let date = format.date(from: text) { return date.timeIntervalSince1970 * 1000 } }
        return nil
    }
    var best: (text: String, created: Double, conversation: Any)?
    for message in found {
        let text = messageText(message)
        guard isInOrder(text, of: sent) else { continue }
        let created = createdMs(message) ?? .infinity // an unreadable time is kept (and taken as the newest)
        guard created >= since - 2000, best == nil || created > best!.created else { continue }
        best = (text, created, message["conversation"] ?? NSNull())
    }
    var result: [String: Any] = ["socket": daemon, "session": session, "conversations": conversations.count, "messages": found.count]
    if let best {
        result["text"] = best.text
        result["conversation"] = best.conversation
    } else {
        result["read_error"] = "no message of the sent keys since Return"
    }
    return result
}

/// Every conversation message (an object with `parts` and `created_at`) anywhere in `node`.
func collectMessages(_ node: Any, into list: inout [[String: Any]]) {
    if let object = node as? [String: Any] {
        if object["parts"] is [Any], object["created_at"] != nil { list.append(object) }
        for value in object.values { collectMessages(value, into: &list) }
    } else if let array = node as? [Any] {
        for value in array { collectMessages(value, into: &list) }
    }
}

/// A message's text: its text parts, joined.
func messageText(_ message: [String: Any]) -> String {
    let parts = message["parts"] as? [[String: Any]] ?? []
    return parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
}

/// Whether `text` (trimmed) is a non-empty run of `sent`'s characters in sent order, each at most once.
func isInOrder(_ text: String, of sent: [Character]) -> Bool {
    let typed = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !typed.isEmpty else { return false }
    var next = 0
    for character in typed {
        guard next < sent.count, let at = sent[next...].firstIndex(of: character) else { return false }
        next = at + 1
    }
    return true
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
    // keys=1: step i's key at the window plus 100 i ms; 3 more once Home is up and took keys, then Return.
    if typesKeys, let seen = windowSeenAt, returnSent == nil, quitSent == nil {
        let step = keyPosts.count
        if keysStopAt == nil, marks["window_usable"] != nil, marks["home.first_page"] != nil {
            keysStopAt = min(step + 3, keySequence.count)
        }
        if step < (keysStopAt ?? keySequence.count) {
            if t >= seen + 100 * Double(step) {
                let character = keySequence[step]
                postKey(keyCodes[character] ?? 0, String(character), to: pid)
                keyPosts.append(t)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { keysFront += 1 }
            }
        } else if (keysStopAt != nil && t >= seen + 100 * Double(step)) || t - seen >= returnBy {
            postKey(returnKeyCode, "\r", to: pid)
            returnSent = t
        }
    }
    if let seen = windowSeenAt, quitSent == nil, t - seen >= settle * 1000 {
        if !plainApp { frontAtQuit = front() }
        if typesKeys { keysRead = sentText(since: returnSent ?? seen, sent: Array(keySequence.prefix(keyPosts.count))) }
        if movesBeforeQuit { moveThenQuit(pid) } else { quitSent = now(); kill(pid, SIGTERM) }
    }
    if window == nil, quitSent == nil, t - requested > 30_000 { failure = "no window in 30 s"; quitSent = t; kill(pid, SIGTERM) }
    // An app quit from outside (dev-loop-ceiling startup_loop SIGTERMs it, as reload.sh does): isTerminated alone can
    // stay false after the process is gone, as launch-premain.swift and background-ready.swift already pair it with
    // kill(pid, 0). 2026-11-21 step 4b9c45ea3d756d968ad03448: "launch-ready floor1 did not end 90 s after its app quit".
    if quitSent == nil, app.isTerminated || kill(pid, 0) != 0 { quitSent = t }
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
            "dfl.settings_read", "dfl.theme", "services.crash_reporting", "dfl.services", "dfl.app_actions", "dfl.bind", "dfl.menu", "dfl.home_history",
            "launch_snapshot_shown", "first_window_flushed", "did_finish_launching_end", "first_window_frame_committed", "home.first_page", "reveal.home",
            "deferred_windows_restored",
            // The live tree applied and the restore began: from launch_snapshot_shown to here the window shows what the
            // snapshot drew, so a stale snapshot was visible this long before the late check (hq#12660).
            "daemon_snapshot_loaded", "launch.no_snapshot",
            // The bare launch's marks (piece 8): Home's composer takes keys; a terminal's shell printed its first output.
            "window_usable", "first_shell_live", "first_key_down",
            // A relaunch's restored terminal: its first frame, and with `type` the key typed at the first window frame,
            // when it left the app for the PTY, and its echo back (LaunchTypeProbe, LaunchInputMarks).
            "first_terminal_content_applied", "first_terminal_frame", "launch.visible_terminals_drawn",
            "terminal.probe_key_typed", "terminal_input_accepted", "terminal_echo"]
// The launch's startup stages (startup-tti), each ms from process start to the earliest of its marks that came: the
// table the app's launch-times.jsonl rows use (LaunchStages, LaunchTimesFile.swift) and scripts/ci/launch_stages.py;
// tests/test_launch_stages.py keeps the three equal.
let launchStages: [(stage: String, marks: [String])] = [
    ("dyld", ["premain.first_initializer"]),
    ("premain", ["main_start"]),
    ("main_setup", ["main.setup_done"]),
    ("did_finish_launching", ["did_finish_launching_start"]),
    ("daemon_connected", ["daemon_connected"]),
    ("first_window_shown", ["launch_snapshot_shown", "first_window_flushed", "dfl.windows"]),
    ("first_frame", ["first_window_frame_committed"]),
    ("webview_ready", ["cef.ready"]),
    ("first_page_navigation", ["first_page.navigation_start"]),
    ("first_page_dom_content_loaded", ["first_page.dom_content_loaded"]),
    ("first_page_contentful_paint", ["first_page.first_contentful_paint"]),
    ("first_chat_paint", ["agent_pane.painted", "agent_pane.newtab_painted", "home.saved_page_shown", "home.first_page"]),
    ("first_browser_paint", ["browser_pane.first_paint"]),
    ("first_interaction", ["terminal_echo", "agent_pane.input_echoed", "window_usable"]),
]
var stages: [String: Double] = [:]
for (stage, names) in launchStages {
    if let first = names.compactMap({ marks[$0] }).filter({ $0.isFinite && $0 >= 0 }).min() { stages[stage] = first.rounded(toPlaces: 1) }
}
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
            || ["dfl.", "home.", "reveal.", "cloud_env.", "app.", "daemon.", "launch_snapshot", "layout.", "web.layout.", "terminal.", "window.", "frame.", "premain.", "main.", "first_page."].contains { mark.key.hasPrefix($0) }
    },
    "all_marks": marks.count,
    "stages": stages,
    "shell_requested": rel(shellRequested),
    // The region the window showed first (home, pane, ...): the region a person saw, whichever it is.
    "first_reveal": marks.filter { $0.key.hasPrefix("reveal.") }.min { $0.value < $1.value }.map { String($0.key.dropFirst("reveal.".count)) } ?? NSNull(),
]
if let frontAtQuit { row["front"] = frontAtQuit }
if plainApp { row["plain"] = true }
// The settle (the app's layout.* marks, LaunchLayoutSettle), in ms after main_start like the summary's: the first frame
// the watch read, the last change after it, and their difference, so a receipt can count pairs moving the same way.
// Row key `settle`: `layout` is the probe's own layout=1 sampling below.
if let first = marks["layout.first_frame"], let last = marks["layout.settle"] {
    func afterMain(_ ms: Double) -> Any { marks["main_start"].map { (ms - $0).rounded(toPlaces: 1) } ?? NSNull() }
    row["settle"] = ["first_frame_ms": afterMain(first), "settle_ms": afterMain(last),
                     "settle_minus_first_frame_ms": (last - first).rounded(toPlaces: 1), "max_move_pt": marks["layout.max_move"] ?? 0]
} else {
    row["settle"] = "none"
}
if typesKeys {
    // first_key_ms: when the earliest sent key the sent message holds went out (step i: the window plus 100 i ms), ms
    // from process start as every time here; null when it holds none, or nothing was read back.
    let sent = Array(keySequence.prefix(keyPosts.count)), text = keysRead?["text"] as? String ?? ""
    let firstStep = sent.firstIndex { text.contains($0) }
    row["first_key_ms"] = firstStep.map { rel(keyPosts[$0]) } ?? NSNull()
    row["keys_sent"] = keyPosts.count
    row["keys_landed"] = sent.filter { text.contains($0) }.count
    row["keys_text"] = keysRead?["text"] ?? NSNull()
    row["keys_front"] = keysFront // keys posted while the app was frontmost
    row["keys_access"] = keysAccess // CGPreflightPostEventAccess; false: postToPid dropped every key
    row["keys_return"] = rel(returnSent)
    var keysReadRow: [String: Any] = keysRead ?? ["read_error": "not read"] // a dictionary, never filter's tuples
    keysReadRow["text"] = nil
    row["keys_read"] = keysReadRow
}
if samplesLayout, window != nil {
    let finished = layoutDone.wait(timeout: .now() + 5) == .success
    row["layout"] = ["window": layoutWindow.row(rel), "sidebar": layoutSidebar.row(rel), "samples": layoutSamples,
                     "sidebar_samples": sidebarSamples, "complete": finished] as [String: Any]
}
if let moveQuit { row["movequit"] = moveQuit }
if let recordDir { row["record_dir"] = recordDir }
if let failure { row["error"] = failure }
let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
print("LR-RUN", String(decoding: data, as: UTF8.self))
exit(window == nil ? 1 : 0)
