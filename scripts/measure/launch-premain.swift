// What a cmux NEXT launch pays before `main` (CMUX-629): the probe scripts/measure/launch-premain.sh runs per launch.
//
//   launch-premain open APP HOME_ROOT LABEL RUN_S [quit|term|settle]
//                                                   open APP through LaunchServices (as the Dock does), wait for its
//                                                   first on-screen window, keep it RUN_S seconds, then quit it the
//                                                   way Cmd-Q does (NSRunningApplication.terminate; SIGTERM after 20 s),
//                                                   or with term end it with SIGTERM ("Quit, keep sessions"); settle
//                                                   ends it as term does, at its window_usable mark or RUN_S seconds
//                                                   past its window, whichever comes first, and adds the settle fields
//   launch-premain exec APP HOME_ROOT LABEL [HOLD] [settle=S]
//                                                   exec APP's executable directly and stop it at its `main_start`
//                                                   mark; with HOLD, start it suspended, print `LP-PID <pid>`, and let
//                                                   it run once the file HOLD exists (a sampler attaches meanwhile);
//                                                   with settle=S, after the readings at main let it run on to its
//                                                   window and its window_usable mark (or S seconds past the window),
//                                                   then SIGTERM, with the settle fields
//   launch-premain stub FILE LABEL                  exec FILE --version and time it to exit (killed at 5 s)
//   launch-premain resident FILE                    print FILE's resident fraction and page counts
//   launch-premain spawn FILE LABEL                 posix_spawn FILE started suspended, time the call (the kernel's
//                                                   exec of the image, its policy check included), then kill it
//
// Each launch prints one `LP-RUN <json>` line. main_start is the app's own mark, in ms from its process start
// (sysctl p_starttime). At the mark (in exec mode with the process stopped there; in open mode as the mark arrives,
// a few ms late) the probe reads the process's rusage: pageins, user and system CPU ms. resident_before and
// resident_at_main are the executable's resident fraction (mincore over a mapping of the file, which faults nothing
// in), before the launch and at main; pages_touched is the difference in pages. On a build whose executable is a stub
// and whose code is Contents/Frameworks/CmuxNextApp.framework (cmux#44204), fw_resident_before, fw_resident_at_main
// and fw_pages_touched say the same of the framework's binary.
//
// The settle fields (open ... settle, exec ... settle=S), ms from process start like main_start:
// first_window_frame_committed, launch_shell.committed (null on a build that has no such mark), window_usable,
// window_on_screen, and settle: window_usable, or window_on_screen + 6000 when the app marked none by the end
// (settle_by says which: window_usable, window+6s, or none with no window). settle_wait_s is the RUN_S or S it waited.
import AppKit
import Darwin

let args = CommandLine.arguments
func usage() -> Never {
    FileHandle.standardError.write(Data("usage: launch-premain open|exec|stub|resident ...\n".utf8)); exit(2)
}
guard args.count >= 3 else { usage() }

// State the main-queue callbacks change: globals, as launch-ready.swift keeps them (a case's locals captured by
// DispatchQueue.main.async's @Sendable closure do not compile).
var running: NSRunningApplication?, failure: String?, mainAt: Double?, row: [String: Any] = [:], child: pid_t = 0
// Mode first's state the CuaDriver press's termination handler changes.
var press = "none", pressed: Double?
final class Lines { var pending = Data(), seen = Set<String>() }

func now() -> Double { var tv = timeval(); gettimeofday(&tv, nil); return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000 }
func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }

struct Resident { var resident: Int; var pages: Int; var fraction: Double { pages == 0 ? 0 : Double(resident) / Double(pages) } }

func resident(_ path: String) -> Resident? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_size > 0 else { return nil }
    let size = Int(st.st_size), page = Int(getpagesize())
    guard let base = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), base != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
    defer { munmap(base, size) }
    let pages = (size + page - 1) / page
    var vec = [CChar](repeating: 0, count: pages)
    guard mincore(base, size, &vec) == 0 else { return nil }
    return Resident(resident: vec.reduce(0) { $0 + (($1 & 1) != 0 ? 1 : 0) }, pages: pages)
}

func processStart(_ pid: pid_t) -> Double? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
}

// The process's pageins and CPU so far (proc_pid_rusage), CPU in ms.
func usage(_ pid: pid_t) -> [String: Any] {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return [:] }
    var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
    let ms = { (t: UInt64) in round1(Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e6) }
    return ["pageins": Int(info.ri_pageins), "user_ms": ms(info.ri_user_time), "system_ms": ms(info.ri_system_time),
            "disk_read_kb": Int(info.ri_diskio_bytesread / 1024)]
}

func systemPageins() -> Int {
    var stats = vm_statistics64(), count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
    return kr == KERN_SUCCESS ? Int(stats.pageins) : -1
}

func emit(_ row: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print("LP-RUN", String(decoding: data, as: UTF8.self)); fflush(stdout)
}

func executable(_ app: URL) -> String {
    let name = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? app.deletingPathExtension().lastPathComponent
    return app.appendingPathComponent("Contents/MacOS/\(name)").path
}

// The framework that holds the app's code when the executable is a stub (cmux#44204), if the bundle has one.
func codeFramework(_ app: URL) -> String? {
    let path = app.appendingPathComponent("Contents/Frameworks/CmuxNextApp.framework/CmuxNextApp").resolvingSymlinksInPath().path
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

// fw_resident_at_main and fw_pages_touched into row, against the framework's residency before the launch.
func frameworkAtMain(_ path: String?, before: Resident?) {
    guard let path else { return }
    let atMain = resident(path)
    row["fw_resident_at_main"] = fraction(atMain)
    if let atMain, let before { row["fw_pages_touched"] = atMain.resident - before.resident }
}

var retained: [AnyObject] = []

// The marks after main a settled launch reports, by name.
let settleMarks: Set<String> = ["first_window_frame_committed", "launch_shell.committed", "window_usable"]

// The settle fields from the marks seen and the window (ms from process start), as the header says.
func settleFields(_ marks: [String: Double], window: Double?, waited: Double) -> [String: Any] {
    var fields: [String: Any] = ["settle_wait_s": waited]
    for name in settleMarks { fields[name] = json(marks[name]) }
    if let usable = marks["window_usable"] {
        fields["settle"] = usable; fields["settle_by"] = "window_usable"
    } else if let window {
        fields["settle"] = round1(window + 6000); fields["settle_by"] = "window+6s"
    } else {
        fields["settle"] = NSNull(); fields["settle_by"] = "none"
    }
    return fields
}

// The marks FIFO, opened read-write first: the app's nonblocking open for writing finds a reader, and with the
// probe as a writer too a read never sees end of file, so the read source fires only on data (read-only, it fires
// without end while no writer is open, a busy core on the Mac being measured). `onMark` runs on the main queue for
// each new mark.
func marksFIFO(_ homeRoot: URL, onMark: @escaping (String, Double) -> Void) -> String {
    let fifo = homeRoot.appendingPathComponent("marks.fifo").path
    unlink(fifo); mkfifo(fifo, 0o600)
    let fd = open(fifo, O_RDWR | O_NONBLOCK)
    let lines = Lines()
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return }
        lines.pending.append(contentsOf: buffer[0..<count])
        while let newline = lines.pending.firstIndex(of: 10) {
            let line = String(decoding: lines.pending[lines.pending.startIndex..<newline], as: UTF8.self)
            lines.pending.removeSubrange(lines.pending.startIndex...newline)
            let parts = line.split(separator: " ")
            if parts.count >= 2, let ms = Double(parts[parts.count - 1]) {
                let name = parts[0..<(parts.count - 1)].joined(separator: " ")
                if lines.seen.insert(name).inserted { onMark(name, ms) }
            }
        }
    }
    source.resume()
    retained.append(source)
    return fifo
}

// JSON for an optional: the value, or null.
func json(_ value: Any?) -> Any { value ?? NSNull() }
func fraction(_ r: Resident?) -> Any { json(r.map { round1($0.fraction * 1000) / 1000 }) }

func environment(_ homeRoot: URL, fifo: String) -> [String: String] {
    let home = homeRoot.appendingPathComponent("h"), tmp = homeRoot.appendingPathComponent("t")
    for sub in ["Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs"] {
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    // The control socket under /tmp: a fleet worker's HOME_ROOT is longer than sun_path's 104 bytes, and an app given a
    // longer path runs with no control socket at all, unlike a person's launch.
    let socket = "/tmp/cmux-lp-\(getuid()).sock"
    unlink(socket)
    var env: [String: String] = [
        "HOME": home.path, "CFFIXED_USER_HOME": home.path, "TMPDIR": tmp.path + "/",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh",
        "CMUX_NEXT_SOCKET_PATH": socket, "CMUX_NEXT_SOCKET_MODE": "allowAll",
        "CMUX_NEXT_LAUNCH_MARKS_PATH": fifo,
    ]
    if let user = ProcessInfo.processInfo.environment["USER"] { env["USER"] = user; env["LOGNAME"] = user }
    return env
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

func runningCopy(_ app: URL) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == app.standardizedFileURL.path && $0.processIdentifier > 0 }
}

func spin(until done: () -> Bool) { while !done() { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) } }

switch args[1] {
case "resident":
    guard let r = resident(args[2]) else { print("LP-RESIDENT none"); exit(1) }
    print("LP-RESIDENT \(round1(r.fraction * 1000) / 1000) \(r.resident) \(r.pages)")

case "spawn":
    guard args.count >= 4 else { usage() }
    var pid: pid_t = 0, attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_START_SUSPENDED))
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(args[2]), nil]
    let started = now()
    let rc = posix_spawn(&pid, args[2], nil, &attr, argv, environ)
    let spawnMs = now() - started
    if rc == 0 { kill(pid, SIGKILL); kill(pid, SIGCONT); var status: Int32 = 0; waitpid(pid, &status, 0) }
    var spawned: [String: Any] = ["label": args[3], "mode": "spawn", "file": (args[2] as NSString).lastPathComponent, "spawn_ms": round1(spawnMs)]
    if rc != 0 { spawned["error"] = "spawn \(rc)" }
    emit(spawned)

case "stub":
    guard args.count >= 4 else { usage() }
    let before = resident(args[2]), sysBefore = systemPageins(), started = now()
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(args[2]), strdup("--version"), nil]
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    guard posix_spawn(&pid, args[2], &actions, nil, argv, environ) == 0 else { emit(["label": args[3], "error": "spawn"]); exit(1) }
    var status: Int32 = 0, exited = false
    while now() - started < 5000 { if waitpid(pid, &status, WNOHANG) == pid { exited = true; break }; usleep(500) }
    let wall = now() - started
    if !exited { kill(pid, SIGKILL); waitpid(pid, &status, 0) }
    emit(["label": args[3], "mode": "stub", "file": (args[2] as NSString).lastPathComponent, "wall_ms": round1(wall),
          "exited": exited, "system_pageins": systemPageins() - sysBefore, "resident_before": fraction(before)])

case "exec":
    guard args.count >= 5 else { usage() }
    let app = URL(fileURLWithPath: args[2]), homeRoot = URL(fileURLWithPath: args[3]), label = args[4]
    let extra = Array(args.dropFirst(5))
    let settleArg = extra.first { $0.hasPrefix("settle=") }
    let settleFor = settleArg.map { Double($0.dropFirst("settle=".count)) ?? -1 }
    if let settleFor, settleFor <= 0 { usage() }
    let hold = extra.first { !$0.hasPrefix("settle=") }
    let exe = executable(app), before = resident(exe)
    let fw = codeFramework(app), fwBefore = fw.flatMap(resident)
    var later: [String: Double] = [:], stoppedMs: Double?
    let fifo = marksFIFO(homeRoot) { name, ms in
        if settleMarks.contains(name) { later[name] = ms }
        guard name == "main_start", mainAt == nil else { return }
        kill(child, SIGSTOP) // stopped at main: rusage and residency below are the pre-main ones
        let stopped = now()
        mainAt = ms
        row = usage(child)
        let atMain = resident(exe)
        row["resident_at_main"] = fraction(atMain)
        if let atMain, let before { row["pages_touched"] = atMain.resident - before.resident }
        frameworkAtMain(fw, before: fwBefore)
        // settle=S: on from main; every later mark includes the time it was stopped (stopped_at_main_ms).
        if settleFor != nil { stoppedMs = round1(now() - stopped); kill(child, SIGCONT) }
    }
    let env = environment(homeRoot, fifo: fifo).map { strdup("\($0.key)=\($0.value)") } + [nil]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), nil]
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    if hold != nil { posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_START_SUSPENDED)) }
    // The app's output goes to a file: on the probe's stdout (the harness's pipe), anything it started would hold
    // the pipe open after the app is killed.
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    let appLog = homeRoot.appendingPathComponent("exec.log").path
    posix_spawn_file_actions_addopen(&actions, 1, appLog, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_addopen(&actions, 2, appLog, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    let sysBefore = systemPageins(), requested = now()
    guard posix_spawn(&child, exe, &actions, &attr, argv, env) == 0 else { emit(["label": label, "error": "spawn"]); exit(1) }
    // posix_spawn returns once the kernel has activated the new image (the code signature and the system's policy
    // check of the executable included); dyld, the frameworks it links and initializers run after, in the child.
    // Started suspended, spawn_ms is the exec alone and resume_to_main is dyld, the linked frameworks and
    // initializers up to main.
    let spawned = now()
    var resumed: Double?
    if let hold {
        print("LP-PID \(child)"); fflush(stdout)
        let waitFrom = now()
        while access(hold, F_OK) != 0, now() - waitFrom < 30_000 { usleep(2000) }
        kill(child, SIGCONT)
        resumed = now()
    }
    let start = processStart(child)
    spin { mainAt != nil || now() - requested > 30_000 }
    let sysPageins = systemPageins() - sysBefore
    var execWindow: Double?
    if let settleFor, mainAt != nil {
        spin {
            if execWindow == nil, ownWindowOnScreen(child) { execWindow = now() }
            return execWindow != nil || now() - requested > 30_000
        }
        spin { later["window_usable"] != nil || now() - (execWindow ?? requested) >= settleFor * 1000 }
        kill(child, SIGTERM)
        let sent = now()
        var reaped: Int32 = 0
        spin { waitpid(child, &reaped, WNOHANG) == child || now() - sent > 10_000 }
        if kill(child, 0) == 0 { kill(child, SIGKILL) }
    } else {
        kill(child, SIGKILL); kill(child, SIGCONT)
    }
    var status: Int32 = 0; waitpid(child, &status, 0)
    let fields: [String: Any] = ["label": label, "mode": "exec", "pid": Int(child), "main_start": json(mainAt), "system_pageins": sysPageins,
                                 "resident_before": fraction(before), "held": hold != nil,
                                 "request_to_start": json(start.map { round1($0 - requested) }),
                                 "spawn_ms": round1(spawned - requested),
                                 "resume_to_main": json(resumed.flatMap { r in start.flatMap { s in mainAt.map { round1(s + $0 - r) } } })]
    row.merge(fields) { $1 }
    if fw != nil { row["fw_resident_before"] = fraction(fwBefore) }
    if let settleFor {
        let windowMs = execWindow.flatMap { w in start.map { round1(w - $0) } }
        row.merge(settleFields(later, window: windowMs, waited: settleFor)) { $1 }
        row["window_on_screen"] = json(windowMs)
        row["stopped_at_main_ms"] = json(stoppedMs)
    }
    if mainAt == nil { row["error"] = "no main_start in 30 s" }
    emit(row)
    exit(mainAt == nil ? 1 : 0)

case "open":
    guard args.count >= 6, let runFor = Double(args[5]) else { usage() }
    let settle = args.count > 6 && args[6] == "settle"
    let endWithTerm = settle || (args.count > 6 && args[6] == "term")
    let app = URL(fileURLWithPath: args[2]), homeRoot = URL(fileURLWithPath: args[3]), label = args[4]
    let exe = executable(app), before = resident(exe)
    let fw = codeFramework(app), fwBefore = fw.flatMap(resident)
    // The marks after main a measured launch reports (launch-reboot.sh), as launch-ready.swift keeps them.
    var later: [String: Double] = [:]
    let fifo = marksFIFO(homeRoot) { name, ms in
        if settleMarks.contains(name) { later[name] = ms }
        guard name == "main_start", mainAt == nil else { return }
        mainAt = ms
        if running == nil { running = runningCopy(app) }
        if let pid = running?.processIdentifier, pid > 0 { row = usage(pid) }
        row["resident_at_main"] = fraction(resident(exe))
        frameworkAtMain(fw, before: fwBefore)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.environment = environment(homeRoot, fifo: fifo)
    configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
    let sysBefore = systemPageins(), requested = now()
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { app, error in
        DispatchQueue.main.async { if let error { failure = "open: \(error.localizedDescription)" }; if running == nil { running = app } }
    }
    var start: Double?, window: Double?, sysPageins: Int?
    spin {
        if running == nil { running = runningCopy(app) }
        if let pid = running?.processIdentifier, pid > 0 {
            if start == nil { start = processStart(pid) }
            if window == nil, ownWindowOnScreen(pid) { window = now() }
        }
        if mainAt != nil, sysPageins == nil { sysPageins = systemPageins() - sysBefore }
        return failure != nil || window != nil || now() - requested > 30_000
    }
    var quit = "none"
    if let target = running {
        spin { (settle && later["window_usable"] != nil) || now() - (window ?? requested) >= runFor * 1000 }
        if endWithTerm { kill(target.processIdentifier, SIGTERM); quit = "term" } else { target.terminate(); quit = "terminate" }
        let sent = now()
        spin { target.isTerminated || kill(target.processIdentifier, 0) != 0 || now() - sent > 20_000 }
        if !(target.isTerminated || kill(target.processIdentifier, 0) != 0) {
            kill(target.processIdentifier, SIGTERM); quit = "sigterm"
            let termAt = now()
            spin { kill(target.processIdentifier, 0) != 0 || now() - termAt > 10_000 }
            if kill(target.processIdentifier, 0) == 0 { kill(target.processIdentifier, SIGKILL); quit = "sigkill" }
        }
    }
    let fields: [String: Any] = ["label": label, "mode": "open", "pid": Int(running?.processIdentifier ?? 0), "main_start": json(mainAt),
                                 "system_pageins": json(sysPageins), "resident_before": fraction(before),
                                 "window_on_screen": json(window.flatMap { w in start.map { round1(w - $0) } }), "run_s": runFor,
                                 "request_to_start": json(start.map { round1($0 - requested) }), "quit": quit,
                                 "first_window_frame_committed": json(later["first_window_frame_committed"]),
                                 "window_usable": json(later["window_usable"])]
    row.merge(fields) { $1 }
    if settle { row.merge(settleFields(later, window: window.flatMap { w in start.map { round1(w - $0) } }, waited: runFor)) { $1 } }
    if fw != nil { row["fw_resident_before"] = fraction(fwBefore) }
    if let failure { row["error"] = failure } else if window == nil { row["error"] = "no window in 30 s" }
    emit(row)
    exit(window == nil ? 1 : 0)

case "first":
    // A new copy's first open, as a person double-clicks it (launch-fresh-install.sh). Times from the open request:
    // the system's "downloaded from the Internet" prompt on screen (a CoreServicesUIAgent window) and gone once its
    // Open is pressed through the console's CuaDriver (LF_CUA), the process start, the app's marks, the first window.
    guard args.count >= 6, let runFor = Double(args[5]) else { usage() }
    let app = URL(fileURLWithPath: args[2]), homeRoot = URL(fileURLWithPath: args[3]), label = args[4]
    var marks: [String: Double] = [:]
    let fifo = marksFIFO(homeRoot) { name, ms in marks[name] = ms; if name == "main_start" { mainAt = ms } }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.environment = environment(homeRoot, fifo: fifo)
    configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
    let requested = now()
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { app, error in
        DispatchQueue.main.async { if let error { failure = "open: \(error.localizedDescription)" }; if running == nil { running = app } }
    }
    var start: Double?, window: Double?, prompt: Double?, promptGone: Double?
    var pressing: Process?
    func onScreen() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }
    func owner(_ info: [String: Any]) -> String { info[kCGWindowOwnerName as String] as? String ?? "?" }
    func windowID(_ info: [String: Any]) -> Int { info[kCGWindowNumber as String] as? Int ?? -1 }
    // CoreServicesUIAgent windows already on screen before the request (a prompt an earlier launch left unanswered)
    // are not this launch's prompt: only a window that came after the request is.
    let agentBefore = Set(onScreen().filter { owner($0) == "CoreServicesUIAgent" }.map(windowID))
    func agentWindow(_ list: [[String: Any]]) -> (pid: Int32, id: Int)? {
        for info in list where owner(info) == "CoreServicesUIAgent" && !agentBefore.contains(windowID(info)) {
            if let pid = info[kCGWindowOwnerPID as String] as? Int32 { return (pid, windowID(info)) }
        }
        return nil
    }
    // Every window owner that came on screen after the request, with when: the prompt, if the system shows it under
    // another owner than CoreServicesUIAgent, is among them.
    let ownersBefore = Set(onScreen().map(owner))
    var newOwners: [String: Double] = [:]
    // Presses the prompt's Open with CuaDriver (it holds the console's Accessibility grant; this probe, built per run,
    // has none): its window state, the AXButton titled Open, a press. The status goes to `press`.
    func pressOpen(pid: Int32, id: Int) {
        guard let cua = ProcessInfo.processInfo.environment["LF_CUA"], FileManager.default.isExecutableFile(atPath: cua) else { press = "no CuaDriver"; return }
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", """
            state="$("$0" call get_window_state "{\\"pid\\":$1,\\"window_id\\":$2,\\"include_accessibility_tree\\":true}" 2>&1)"
            token="$(printf '%s' "$state" | /usr/bin/python3 -I -c '
            import json, sys
            a = json.load(sys.stdin); s = a.get("structuredContent") if isinstance(a.get("structuredContent"), dict) else a
            for e in s.get("elements") or []:
                if e.get("role") == "AXButton" and "Open" in (str(e.get("title")), str(e.get("label"))) and e.get("element_token"):
                    print(e["element_token"]); break
            ' 2>/dev/null)"
            [ -n "$token" ] || { echo "no Open button: $(printf '%s' "$state" | head -c 300)"; exit 1; }
            "$0" call click "{\\"pid\\":$1,\\"window_id\\":$2,\\"element_token\\":\\"$token\\",\\"action\\":\\"press\\"}" >/dev/null 2>&1 && echo pressed
            """, cua, String(pid), String(id)]
        task.standardOutput = pipe; task.standardError = pipe
        task.terminationHandler = { _ in
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { press = String(text.prefix(300)); pressed = now() }
        }
        do { try task.run(); pressing = task } catch { press = "run: \(error)" }
    }
    spin {
        if running == nil { running = runningCopy(app) ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == Bundle(url: app)?.bundleIdentifier && $0.processIdentifier > 0 && $0.launchDate.map { $0.timeIntervalSince1970 * 1000 >= requested - 1000 } == true } }
        if start == nil, let pid = running?.processIdentifier, pid > 0 { start = processStart(pid) }
        let list = onScreen()
        for info in list where !ownersBefore.contains(owner(info)) && newOwners[owner(info)] == nil { newOwners[owner(info)] = round1(now() - requested) }
        if let found = agentWindow(list) {
            if prompt == nil { prompt = now(); pressOpen(pid: found.pid, id: found.id) }
        } else if prompt != nil, promptGone == nil { promptGone = now() }
        if window == nil, let pid = running?.processIdentifier, pid > 0, ownWindowOnScreen(pid) { window = now() }
        return failure != nil || window != nil || now() - requested > 60_000
    }
    // The marks after the window (window_usable) for up to RUN_S more seconds, then SIGTERM.
    spin { marks["window_usable"] != nil || now() - (window ?? requested) >= runFor * 1000 }
    pressing?.waitUntilExit()
    let path = running?.bundleURL?.path ?? ""
    if let pid = running?.processIdentifier, pid > 0 {
        kill(pid, SIGTERM)
        let sent = now()
        spin { kill(pid, 0) != 0 || now() - sent > 10_000 }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
    let since = { (t: Double?) in json(t.map { round1($0 - requested) }) }
    // Process-relative marks, as the app writes them, moved onto the request's clock.
    let fromRequest = { (name: String) -> Any in json(start.flatMap { s in marks[name].map { round1(s + $0 - requested) } }) }
    let fields: [String: Any] = [
        "label": label, "mode": "first", "pid": Int(running?.processIdentifier ?? 0),
        "prompt": since(prompt), "prompt_gone": since(promptGone), "pressed": since(pressed), "press": press,
        "start": since(start), "main": fromRequest("main_start"), "window": since(window), "usable": fromRequest("window_usable"),
        "main_start": json(mainAt), "translocated": path.contains("/AppTranslocation/"), "ran_from": path,
        "marks": marks.mapValues(round1), "new_window_owners": newOwners, "prompts_before": agentBefore.count,
        "prompt_left": agentWindow(onScreen()) != nil,
    ]
    row.merge(fields) { $1 }
    if let failure { row["error"] = failure } else if window == nil { row["error"] = "no window in 60 s" }
    emit(row)
    exit(window == nil ? 1 : 0)

default:
    usage()
}
