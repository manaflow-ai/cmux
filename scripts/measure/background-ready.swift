// One arm of background-ready.sh: a cmux NEXT copy brought back from the background, timed from outside the app.
//
//   background-ready ARM APP HOME_ROOT RUNS SETTLE_S SOCKET IDLE_S IDLE_READER CONFIG_FILE
//
// One long-lived process per arm: it holds the marks FIFO (CMUX_NEXT_LAUNCH_MARKS_PATH, lines "NAME MS" in ms since
// the app's process start) for the whole arm, because a running app opens it once. A priming launch (a new instance,
// as launch-ready.swift opens one: same environment, same probe clock), then RUNS rounds. Each round puts the app in
// the arm's background state and then makes the open request:
//   cold   SIGTERM ("Quit, keep sessions", as launch-ready), the copy's processes gone, then a new instance
//   hide   NSRunningApplication.hide() (Cmd-H) until the app has no window on screen
//   close  `action.run closeWindow` on the app's socket until no window is on screen, then until the activation
//          policy is .accessory (app.hideDockIconWithoutWindows, on by default: no Dock icon, a menu bar item)
//   quit   NSRunningApplication.terminate() (a quit Apple event: an interactive quit). A process that exits makes the
//          round a cold relaunch (exited: true); one alive with no window for 10 s is shown again
// The warm open request is what a Dock click or `open` of the running app does: NSWorkspace.openApplication with
// createsNewApplicationInstance = false, activates = true. Times in each `BR-RUN ARM {json}` row are ms since the
// open request (window_on_screen, active; frame_committed and usable from the app's marks); a cold row also carries
// launch-ready's process-start clock (*_since_start, request_to_start). A warm show's marks are named reopen.<name>
// (written by builds that have them; a nightly writes none) and the last of each after the request is kept.
// IDLE_S > 0: once per arm, IDLE_READER (background-ready-idle.py) measures the app's processes for IDLE_S seconds,
// 60 s after the arm's first background state is reached (cold: with its window shown; and its quit's leftovers for
// up to 60 s), and prints BR-IDLE. The app stays running at the end: background-ready.sh stops it by pid.
import AppKit
import Darwin

let args = CommandLine.arguments
guard args.count >= 10 else {
    FileHandle.standardError.write(Data("usage: background-ready ARM APP HOME_ROOT RUNS SETTLE_S SOCKET IDLE_S IDLE_READER CONFIG_FILE\n".utf8)); exit(2)
}
let arm = args[1], appURL = URL(fileURLWithPath: args[2]), homeRoot = URL(fileURLWithPath: args[3])
let runs = Int(args[4]) ?? 5, settle = Double(args[5]) ?? 6, socketPath = args[6]
let idleSeconds = Double(args[7]) ?? 0, idleReader = args[8], configFile = args[9]
guard ["cold", "hide", "close", "quit"].contains(arm) else { FileHandle.standardError.write(Data("background-ready: arm \(arm)\n".utf8)); exit(2) }
guard socketPath.utf8.count <= 103 else { // sun_path less its NUL: the app could bind no socket there
    FileHandle.standardError.write(Data("background-ready: socket path \(socketPath.utf8.count) bytes, over 103: \(socketPath)\n".utf8)); exit(2)
}
let idleSettle = 60.0 // after the first background state, before the idle window
let showGap = 2.0 // from a background state reached to the open request
let home = homeRoot.appendingPathComponent("h"), tmp = homeRoot.appendingPathComponent("t")
for sub in ["Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs"] {
    try? FileManager.default.createDirectory(at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
}
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func now() -> Double { var tv = timeval(); gettimeofday(&tv, nil); return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000 }
func emit(_ tag: String, _ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(tag, arm, String(decoding: data, as: UTF8.self)); fflush(stdout)
}
func fail(_ text: String) { print("BR-FAIL", arm, text); fflush(stdout) }
extension Double { func rounded(toPlaces places: Int) -> Double { let p = pow(10, Double(places)); return (self * p).rounded() / p } }

func processStart(_ pid: pid_t) -> Double? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
}

func load1m() -> Any {
    var loads = [Double](repeating: 0, count: 3)
    guard getloadavg(&loads, 3) > 0 else { return NSNull() }
    return loads[0].rounded(toPlaces: 2)
}

// The marks FIFO, read for the whole arm. A second descriptor opened for writing keeps it from reading end-of-file
// whenever no app has it open (between a quit and the next launch), which would wake the read source without end.
let fifo = homeRoot.appendingPathComponent("marks.fifo").path
unlink(fifo); mkfifo(fifo, 0o600)
let fifoFD = open(fifo, O_RDONLY | O_NONBLOCK)
let fifoKeeper = open(fifo, O_WRONLY | O_NONBLOCK)
var marks: [(name: String, ms: Double)] = [], pending = Data()
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
            marks.append((parts[0..<(parts.count - 1)].joined(separator: " "), ms))
        }
    }
}
markSource.resume()
// The run loop always has a source, so a wait below sleeps until its own deadline instead of spinning.
let keepAlive = Timer(timeInterval: 0.5, repeats: true) { _ in }
RunLoop.main.add(keepAlive, forMode: .common)

/// Runs the main run loop until `check` is true (polled every ms, launch-ready's probe clock) or `seconds` pass.
@discardableResult
func spin(_ seconds: Double, _ check: () -> Bool) -> Bool {
    let deadline = now() + seconds * 1000
    while now() < deadline {
        if check() { return true }
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    }
    return check()
}
/// Waits `seconds` with the run loop serviced (marks keep arriving) and no polling.
func rest(_ seconds: Double) {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline { RunLoop.main.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.5))) }
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

func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

// One request on the app's control socket (line JSON, release methods only): its result, or nil.
func rpc(_ method: String, _ params: [String: Any] = [:]) -> [String: Any]? {
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
    let message: [String: Any] = ["id": 1, "method": method, "params": params]
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
    return object["result"] as? [String: Any] ?? [:]
}

// What is in front, as launch-ready.swift reads it (snapshot.get's focused workspace key and tab, context.keys'
// topPage), read after each show's settle.
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
func snapshotWindows() -> Any {
    guard let windows = (rpc("snapshot.get")?["topology"] as? [String: Any])?["windows"] as? [Any] else { return NSNull() }
    return windows.count
}

func policyName(_ app: NSRunningApplication) -> String {
    switch app.activationPolicy {
    case .regular: return "regular"
    case .accessory: return "accessory"
    case .prohibited: return "prohibited"
    @unknown default: return "unknown"
    }
}

/// How many processes run from the copy's Contents/MacOS or Contents/Frameworks (launch-ready.sh's quiesce_left).
func copyProcesses() -> Int {
    let ps = Process(), pipe = Pipe()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "command="]
    ps.standardOutput = pipe
    guard (try? ps.run()) != nil else { return 0 }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    let roots = [appURL.path + "/Contents/MacOS/", appURL.path + "/Contents/Frameworks/"]
    return text.split(separator: "\n").filter { line in roots.contains { line.contains($0) } }.count
}
/// launch-ready.sh's quiesce: before a new instance, no process of the copy's last run is left (at most 60 s), then 2 s.
func quiesce() -> [String: Any] {
    let started = now()
    var left = copyProcesses()
    while left > 0, now() - started < 60_000 { rest(0.1); left = copyProcesses() }
    let waited = (now() - started).rounded(toPlaces: 0)
    rest(2)
    return ["waited_ms": waited, "left": left]
}

// The marks a row keeps: launch-ready's list and prefixes, and every reopen.* mark.
let keep = ["main_start", "main.nsapp", "main.run", "did_finish_launching_start", "launch_snapshot_shown", "first_window_flushed",
            "did_finish_launching_end", "first_window_frame_committed", "home.first_page", "deferred_windows_restored", "window_usable",
            "first_shell_live"]
func kept(_ name: String, prime: Bool) -> Bool {
    prime || keep.contains(name) || ["reopen.", "dfl.", "home.", "reveal.", "launch_snapshot"].contains { name.hasPrefix($0) }
}

var app: NSRunningApplication?
var lastFront: [String: Any]?
// What the open request's completion reported (globals: the completion is a @Sendable closure).
var opened: NSRunningApplication?, failure: String?
var readerOutput = Data()

/// Opens the copy and times it to its window on screen and active. `cold`: a new instance with the arm's home, as
/// launch-ready.swift opens it; else the running app, as a Dock click does. After the window shows it waits SETTLE_S
/// (marks keep arriving), reads the front and returns the row.
func show(label: String, cold: Bool, extra: [String: Any]) -> [String: Any] {
    var row: [String: Any] = extra
    row["label"] = label; row["cold"] = cold; row["load_1m"] = load1m()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = cold
    configuration.activates = true
    configuration.addsToRecentItems = false
    if cold {
        var environment: [String: String] = [
            "HOME": home.path, "CFFIXED_USER_HOME": home.path, "TMPDIR": tmp.path + "/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh",
            "CMUX_NEXT_SOCKET_PATH": socketPath, "CMUX_NEXT_SOCKET_MODE": "allowAll",
            "CMUX_NEXT_LAUNCH_MARKS_PATH": fifo, "CMUX_NEXT_CONFIG_FILE": configFile,
        ]
        if let user = ProcessInfo.processInfo.environment["USER"] { environment["USER"] = user; environment["LOGNAME"] = user }
        configuration.environment = environment
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        app = nil
    }
    let before = app
    row["active_before"] = before?.isActive ?? false
    marks.removeAll()
    opened = nil; failure = nil
    let requested = now()
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { running, error in
        DispatchQueue.main.async {
            if let error { failure = "open: \(error.localizedDescription)" }
            if let running { opened = running }
        }
    }
    var start: Double?, finished: Double?, window: Double?, active: Double?
    spin(30) {
        let t = now()
        if app == nil {
            app = opened ?? NSWorkspace.shared.runningApplications.first {
                $0.bundleURL?.standardizedFileURL.path == appURL.standardizedFileURL.path && $0.processIdentifier > 0
                    && ($0.launchDate.map { $0.timeIntervalSince1970 * 1000 >= requested - 1000 } ?? true)
            }
        }
        guard let app else { return failure != nil }
        let pid = app.processIdentifier
        if start == nil { start = processStart(pid) }
        if finished == nil, app.isFinishedLaunching { finished = t }
        if active == nil, app.isActive { active = t }
        if window == nil, ownWindowOnScreen(pid) { window = t }
        return (window != nil && active != nil) || failure != nil || (cold && app.isTerminated)
    }
    if window != nil, active == nil { spin(5) { if app?.isActive == true { active = now() }; return active != nil } }
    if let opened, let before, opened.processIdentifier != before.processIdentifier { row["opened_pid"] = opened.processIdentifier }
    if window != nil { rest(settle) }
    let pid = app?.processIdentifier ?? 0
    let since = { (value: Double?) -> Any in
        guard let value else { return NSNull() }
        return (value - requested).rounded(toPlaces: 1)
    }
    row["pid"] = pid
    row["window_on_screen"] = since(window)
    row["active"] = since(active)
    // The app's marks are ms since its process start; since the request they are mark + start - request.
    let offset = start.map { $0 - requested }
    var first: [String: Double] = [:], last: [String: Double] = [:]
    for mark in marks { if first[mark.name] == nil { first[mark.name] = mark.ms }; last[mark.name] = mark.ms }
    var chosen = first
    for (name, ms) in last where name.hasPrefix("reopen.") { chosen[name] = ms }
    row["marks"] = chosen.filter { kept($0.key, prime: label == "prime") }
    row["all_marks"] = marks.count
    let sinceRequest = { (name: String) -> Any in
        guard let ms = chosen[name], let offset else { return NSNull() }
        return (ms + offset).rounded(toPlaces: 1)
    }
    row["frame_committed"] = sinceRequest(cold ? "first_window_frame_committed" : "reopen.first_frame_committed")
    row["usable"] = sinceRequest(cold ? "window_usable" : "reopen.window_usable")
    if !cold {
        row["reopen_since_request"] = chosen.filter { $0.key.hasPrefix("reopen.") }.mapValues { ms in offset.map { (ms + $0).rounded(toPlaces: 1) } ?? ms }
    } else if let start {
        let rel = { (value: Double?) -> Any in
            guard let value else { return NSNull() }
            return (value - start).rounded(toPlaces: 1)
        }
        row["request_to_start"] = (start - requested).rounded(toPlaces: 1)
        row["finished_launching_since_start"] = rel(finished)
        row["window_on_screen_since_start"] = rel(window)
        row["active_since_start"] = rel(active)
    }
    if window != nil {
        let read = front()
        row["front"] = read
        // The front a show opened against the one the show before it left (launch-ready's LR-REOPENED rule).
        if label != "prime", let lastFront, read["error"] == nil, lastFront["error"] == nil {
            row["reopened"] = (read["workspace"] as? String) == (lastFront["workspace"] as? String)
                && (read["top_page"] as? String) == (lastFront["top_page"] as? String)
        }
        lastFront = read
    }
    if let failure { row["error"] = failure } else if window == nil { row["error"] = "no window in 30 s" }
    return row
}

/// IDLE_READER over the app's processes (pid 0: only the copy's leftovers, after a quit). Prints its BR-IDLE line.
func measureIdle(state: String, pid: pid_t, seconds: Double) {
    let reader = Process(), pipe = Pipe()
    reader.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    reader.arguments = ["-I", idleReader, "measure", appURL.path, String(pid), String(seconds), arm, state]
    reader.standardOutput = pipe
    do { try reader.run() } catch { fail("idle \(state): \(error.localizedDescription)"); return }
    readerOutput = Data()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        DispatchQueue.main.async { readerOutput.append(chunk) }
    }
    while reader.isRunning { rest(0.5) }
    pipe.fileHandleForReading.readabilityHandler = nil
    rest(0.1) // the handler's last chunk
    readerOutput.append(pipe.fileHandleForReading.readDataToEndOfFile())
    let text = String(decoding: readerOutput, as: UTF8.self)
    for line in text.split(separator: "\n") { print(line) }
    fflush(stdout)
    if reader.terminationStatus != 0 { fail("idle \(state): reader exited \(reader.terminationStatus)") }
}

/// SIGTERM, as launch-ready quits: the process gone (30 s, then SIGKILL), then the copy's processes.
func sigtermQuit() -> [String: Any] {
    guard let running = app else { return ["error": "no app"] }
    let pid = running.processIdentifier, sent = now()
    kill(pid, SIGTERM)
    var killed = false
    if !spin(30, { running.isTerminated || !alive(pid) }) { kill(pid, SIGKILL); killed = true; spin(5) { !alive(pid) } }
    var out: [String: Any] = ["action": "sigterm", "exit_ms": (now() - sent).rounded(toPlaces: 1), "sigkill": killed]
    out["quiesce"] = quiesce()
    return out
}

/// Puts the running app in the arm's background state. Returns what it did and whether the process exited.
func background() -> (info: [String: Any], exited: Bool) {
    guard let running = app else { return (["error": "no app"], false) }
    let pid = running.processIdentifier, began = now()
    var info: [String: Any] = ["action": arm]
    var reached = false, exited = false
    switch arm {
    case "hide":
        info["hide_returned"] = running.hide()
        reached = spin(10) { !ownWindowOnScreen(pid) }
        info["hidden"] = running.isHidden
    case "close":
        var requests = 0, refused = 0
        while ownWindowOnScreen(pid), requests < 20 {
            requests += 1
            if rpc("action.run", ["action": "closeWindow"]) == nil { refused += 1 }
            spin(1) { !ownWindowOnScreen(pid) }
        }
        let windowsGone = !ownWindowOnScreen(pid)
        info["windows_gone_ms"] = (now() - began).rounded(toPlaces: 1)
        let accessory = spin(10) { running.activationPolicy == .accessory }
        reached = windowsGone && accessory
        info["close_requests"] = requests; info["close_refused"] = refused
        info["snapshot_windows"] = snapshotWindows()
        if !accessory { info["error"] = "activation policy stayed \(policyName(running))" }
    case "quit":
        info["terminate_returned"] = running.terminate()
        // Exited, or alive with no window on screen for 10 s running (a quit's windows go before its process ends).
        var noWindowSince: Double?
        spin(30) {
            if running.isTerminated || !alive(pid) { exited = true; return true }
            if ownWindowOnScreen(pid) { noWindowSince = nil } else if noWindowSince == nil { noWindowSince = now() }
            return noWindowSince.map { now() - $0 >= 10_000 } ?? false
        }
        reached = exited || noWindowSince != nil
        if exited { info["exit_ms"] = (now() - began).rounded(toPlaces: 1); info["quiesce"] = quiesce() }
    default:
        break
    }
    info["reached"] = reached
    info["reached_ms"] = (now() - began).rounded(toPlaces: 1)
    if !exited { info["policy"] = policyName(running) }
    if !reached, info["error"] == nil { info["error"] = "background state not reached" }
    return (info, exited)
}

// The priming launch: the home's state, as launch-ready's.
let prime = show(label: "prime", cold: true, extra: ["exited": false])
emit("BR-RUN", prime)
guard prime["error"] == nil, app != nil else { fail("prime launch: \(prime["error"] ?? "no app")"); exit(1) }
var failures = 0
for round in 1...runs {
    var extra: [String: Any] = ["round": round]
    var cold = false
    if arm == "cold" {
        if round == 1, idleSeconds > 0, let pid = app?.processIdentifier {
            rest(idleSettle)
            measureIdle(state: "shown", pid: pid, seconds: idleSeconds)
        }
        let quit = sigtermQuit()
        if round == 1, idleSeconds > 0 { measureIdle(state: "quit", pid: 0, seconds: min(idleSeconds, 60)) }
        extra["background"] = quit; extra["exited"] = true; cold = true
    } else {
        let (info, exited) = background()
        extra["background"] = info; extra["exited"] = exited; cold = exited
        if let error = info["error"] { extra["error"] = "background: \(error)" }
        let reachedAt = now()
        if round == 1, idleSeconds > 0 {
            rest(idleSettle)
            measureIdle(state: exited ? "quit" : (arm == "hide" ? "hidden" : arm == "close" ? "closed" : "quit_alive"),
                        pid: exited ? 0 : (app?.processIdentifier ?? 0), seconds: exited ? min(idleSeconds, 60) : idleSeconds)
        }
        if !exited { rest(max(0, showGap - (now() - reachedAt) / 1000)) }
        extra["hidden_s"] = ((now() - reachedAt) / 1000).rounded(toPlaces: 1)
    }
    var row = show(label: "run\(round)", cold: cold, extra: extra)
    if let error = extra["error"], row["error"] == nil { row["error"] = error }
    emit("BR-RUN", row)
    if row["error"] != nil { failures += 1; fail("run\(round): \(row["error"]!)") }
    if row["window_on_screen"] is NSNull { break } // nothing to bring back from
}
print("BR-PID", arm, app?.processIdentifier ?? 0); fflush(stdout)
close(fifoKeeper)
exit(failures == 0 ? 0 : 1)
