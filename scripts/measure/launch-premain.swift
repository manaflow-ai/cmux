// What a cmux NEXT launch pays before `main` (CMUX-629): the probe scripts/measure/launch-premain.sh runs per launch.
//
//   launch-premain open APP HOME_ROOT LABEL RUN_S [quit|term]
//                                                   open APP through LaunchServices (as the Dock does), wait for its
//                                                   first on-screen window, keep it RUN_S seconds, then quit it the
//                                                   way Cmd-Q does (NSRunningApplication.terminate; SIGTERM after 20 s),
//                                                   or with term end it with SIGTERM ("Quit, keep sessions")
//   launch-premain exec APP HOME_ROOT LABEL [HOLD]  exec APP's executable directly and stop it at its `main_start`
//                                                   mark; with HOLD, start it suspended, print `LP-PID <pid>`, and let
//                                                   it run once the file HOLD exists (a sampler attaches meanwhile)
//   launch-premain stub FILE LABEL                  exec FILE --version and time it to exit (killed at 5 s)
//   launch-premain resident FILE                    print FILE's resident fraction and page counts
//
// Each launch prints one `LP-RUN <json>` line. main_start is the app's own mark, in ms from its process start
// (sysctl p_starttime). At the mark (in exec mode with the process stopped there; in open mode as the mark arrives,
// a few ms late) the probe reads the process's rusage: pageins, user and system CPU ms. resident_before and
// resident_at_main are the executable's resident fraction (mincore over a mapping of the file, which faults nothing
// in), before the launch and at main; pages_touched is the difference in pages. On a build whose executable is a stub
// and whose code is Contents/Frameworks/CmuxNextApp.framework (cmux#44204), fw_resident_before, fw_resident_at_main
// and fw_pages_touched say the same of the framework's binary.
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
    var env: [String: String] = [
        "HOME": home.path, "CFFIXED_USER_HOME": home.path, "TMPDIR": tmp.path + "/",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "SHELL": "/bin/zsh",
        "CMUX_NEXT_SOCKET_PATH": homeRoot.appendingPathComponent("app.sock").path, "CMUX_NEXT_SOCKET_MODE": "allowAll",
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
    let hold = args.count > 5 ? args[5] : nil
    let exe = executable(app), before = resident(exe)
    let fw = codeFramework(app), fwBefore = fw.flatMap(resident)
    let fifo = marksFIFO(homeRoot) { name, ms in
        guard name == "main_start", mainAt == nil else { return }
        kill(child, SIGSTOP) // stopped at main: rusage and residency below are the pre-main ones
        mainAt = ms
        row = usage(child)
        let atMain = resident(exe)
        row["resident_at_main"] = fraction(atMain)
        if let atMain, let before { row["pages_touched"] = atMain.resident - before.resident }
        frameworkAtMain(fw, before: fwBefore)
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
    if let hold {
        print("LP-PID \(child)"); fflush(stdout)
        let waitFrom = now()
        while access(hold, F_OK) != 0, now() - waitFrom < 30_000 { usleep(2000) }
        kill(child, SIGCONT)
    }
    let start = processStart(child)
    spin { mainAt != nil || now() - requested > 30_000 }
    let sysPageins = systemPageins() - sysBefore
    kill(child, SIGKILL); kill(child, SIGCONT)
    var status: Int32 = 0; waitpid(child, &status, 0)
    let fields: [String: Any] = ["label": label, "mode": "exec", "pid": Int(child), "main_start": json(mainAt), "system_pageins": sysPageins,
                                 "resident_before": fraction(before), "held": hold != nil,
                                 "request_to_start": json(start.map { round1($0 - requested) })]
    row.merge(fields) { $1 }
    if fw != nil { row["fw_resident_before"] = fraction(fwBefore) }
    if mainAt == nil { row["error"] = "no main_start in 30 s" }
    emit(row)
    exit(mainAt == nil ? 1 : 0)

case "open":
    guard args.count >= 6, let runFor = Double(args[5]) else { usage() }
    let endWithTerm = args.count > 6 && args[6] == "term"
    let app = URL(fileURLWithPath: args[2]), homeRoot = URL(fileURLWithPath: args[3]), label = args[4]
    let exe = executable(app), before = resident(exe)
    let fw = codeFramework(app), fwBefore = fw.flatMap(resident)
    let fifo = marksFIFO(homeRoot) { name, ms in
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
        spin { now() - (window ?? requested) >= runFor * 1000 }
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
                                 "request_to_start": json(start.map { round1($0 - requested) }), "quit": quit]
    row.merge(fields) { $1 }
    if fw != nil { row["fw_resident_before"] = fraction(fwBefore) }
    if let failure { row["error"] = failure } else if window == nil { row["error"] = "no window in 30 s" }
    emit(row)
    exit(window == nil ? 1 : 0)

default:
    usage()
}
