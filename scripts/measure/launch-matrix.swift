// One launch of ANY .app, timed the same way for every app (scripts/measure/launch-matrix.sh runs it per launch).
//
//   launch-matrix grants                               which grants this probe has (LM-GRANTS json)
//   launch-matrix run APP LABEL SETTLE_S [ARG...]      open APP through LaunchServices as the Dock does (a new instance,
//                                                       activated), time it, sample its process tree, quit it
//   launch-matrix growth APP LABEL MINUTES [ARG...]    open APP the same way, then one LM-GROWTH line per minute for
//                                                       MINUTES, then quit it (start it with nohup; read the log later)
//   launch-matrix evict PATH                           drop every regular file under PATH from the page cache with no
//                                                       root (mmap + msync MS_INVALIDATE); LM-EVICT says the resident
//                                                       pages before and after
// ARGs after the fixed ones: `--` then the app's own arguments (a Chromium --user-data-dir), and env=K=V pairs before
// the `--` (cmux NEXT's HOME). LM_CUA names the console's CuaDriver (default /Applications/CuaDriver.app's).
//
// `run` prints one `LM-RUN <json>`, times in ms from the LaunchServices open request:
//   proc_start          the app's kernel p_starttime
//   window_on_screen    the first on-screen layer-0 window >= 300x200 owned by any process of the app's tree,
//                       CGWindowList polled every <= 4 ms
//   first_visible_frame the first capture of that window whose pixels are not one colour (frame_source says how:
//                       "cuadriver" through CuaDriver's zoom of the window (frame_resolution_ms: that capture's own
//                       length), else "window", window_on_screen again)
//   interactive         the first key that was accepted: once the window holds still, a harmless letter is posted to
//                       the app's pid (CuaDriver press_key, background delivery) every round until the window's pixels
//                       change, or CuaDriver reads the key back from the focused control (interactive_evidence: pixels
//                       or ax_readback); the time is that key's post. interactive_rounds, interactive_resolution_ms. null with
//                       interactive_blocker when no key was taken in 30 s (a login wall, onboarding) or no route exists
//   at_interactive, settled  resources over the app's whole tree (the app, its descendants, and every process whose
//                       responsible pid is the app's: XPC services): procs, threads, rss_mb, footprint_mb, cpu_ms
//                       (summed user+system since each process began), disk_read_mb, disk_written_mb, pageins,
//                       wakeups; at_interactive at the first accepted key (window + 2 s with none), settled after
//                       SETTLE_S idle seconds, with idle_cpu_pct and idle_wakeups_per_s over that window
// Processes that ended before a sample are not in it (their CPU and disk reads are lost), as procs.py's tree is.
import AppKit
import Darwin

let args = CommandLine.arguments
func usage() -> Never {
    FileHandle.standardError.write(Data("usage: launch-matrix grants|run|growth|evict ...\n".utf8)); exit(2)
}
guard args.count >= 2 else { usage() }

func now() -> Double { var tv = timeval(); gettimeofday(&tv, nil); return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000 }
func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
func json(_ value: Any?) -> Any { value ?? NSNull() }
func emit(_ tag: String, _ row: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(tag, String(decoding: data, as: UTF8.self)); fflush(stdout)
}
func spin(until done: () -> Bool) { while !done() { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) } }
func pause(_ ms: Double) { let end = now() + ms; spin { now() >= end } }

// MARK: grants

let cua = ProcessInfo.processInfo.environment["LM_CUA"] ?? "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
func grants() -> [String: Any] {
    ["post_event": CGPreflightPostEventAccess(), "screen_capture": CGPreflightScreenCaptureAccess(),
     "ax_trusted": AXIsProcessTrusted(), "cuadriver": FileManager.default.isExecutableFile(atPath: cua)]
}

// MARK: the process tree

typealias Responsible = @convention(c) (pid_t) -> pid_t
let responsibleFn: Responsible? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: Responsible.self) }

func allPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(max(got, 0)))).filter { $0 > 0 }
}

func parent(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    return size == Int32(MemoryLayout<proc_bsdinfo>.size) ? pid_t(info.pbi_ppid) : nil
}

// The app, its descendants, and the processes it is responsible for (XPC services launchd started on its behalf).
func tree(_ root: pid_t) -> [pid_t] {
    let pids = allPids()
    var parents: [pid_t: pid_t] = [:]
    for pid in pids { if let p = parent(pid) { parents[pid] = p } }
    var members: Set<pid_t> = [root]
    var grew = true
    while grew {
        grew = false
        for pid in pids where !members.contains(pid) {
            if let p = parents[pid], members.contains(p) { members.insert(pid); grew = true; continue }
            if let fn = responsibleFn, fn(pid) == root { members.insert(pid); grew = true }
        }
    }
    return members.filter { kill($0, 0) == 0 || errno == EPERM }.sorted()
}

var timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func machMs(_ t: UInt64) -> Double { Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

struct Usage { var procs = 0, threads = 0, rss = 0.0, footprint = 0.0, cpuMs = 0.0, read = 0.0, written = 0.0, pageins = 0, wakeups = 0 }

func sample(_ root: pid_t) -> Usage {
    var u = Usage()
    for pid in tree(root) {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { continue }
        u.procs += 1
        u.rss += Double(info.ri_resident_size) / 1_048_576
        u.footprint += Double(info.ri_phys_footprint) / 1_048_576
        u.cpuMs += machMs(info.ri_user_time + info.ri_system_time)
        u.read += Double(info.ri_diskio_bytesread) / 1_048_576
        u.written += Double(info.ri_diskio_byteswritten) / 1_048_576
        u.pageins += Int(info.ri_pageins)
        u.wakeups += Int(info.ri_interrupt_wkups + info.ri_pkg_idle_wkups)
        var task = proc_taskinfo()
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) {
            u.threads += Int(task.pti_threadnum)
        }
    }
    return u
}

func fields(_ u: Usage) -> [String: Any] {
    ["procs": u.procs, "threads": u.threads, "rss_mb": round1(u.rss), "footprint_mb": round1(u.footprint), "cpu_ms": round1(u.cpuMs),
     "disk_read_mb": round1(u.read), "disk_written_mb": round1(u.written), "pageins": u.pageins, "wakeups": u.wakeups]
}

// MARK: windows

struct Window { var id: Int; var pid: pid_t; var width: Double; var height: Double }

func treeWindow(_ members: Set<pid_t>) -> Window? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32, members.contains(pid),
              (info[kCGWindowLayer as String] as? Int) == 0, ((info[kCGWindowAlpha as String] as? Double) ?? 0) > 0,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double, w >= 300, h >= 200 else { continue }
        return Window(id: info[kCGWindowNumber as String] as? Int ?? 0, pid: pid, width: w, height: h)
    }
    return nil
}

// MARK: CuaDriver: captures and keys (the console's CuaDriver holds Screen Recording and Accessibility; this probe,
// built per run, holds neither: launch-fresh-install.sh presses Gatekeeper's Open the same way)

func cuaCall(_ tool: String, _ payload: [String: Any]) -> Data? {
    let task = Process(), pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: cua)
    let body = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    task.arguments = ["call", tool, body]
    task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return task.terminationStatus == 0 ? data : nil
}

// A 32x32 grey grid of the window's pixels, or nil when no capture came back.
func cuaCapture(_ w: Window) -> [UInt8]? {
    guard let data = cuaCall("zoom", ["pid": Int(w.pid), "window_id": w.id, "x1": 0, "y1": 0, "x2": w.width, "y2": w.height]),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let content = (obj["structuredContent"] as? [String: Any]) ?? obj
    var b64 = (content["image_b64"] ?? content["screenshot_b64"] ?? content["data"] ?? content["screenshot_jpeg_b64"]) as? String
    if b64 == nil { b64 = content.first { $0.key.hasSuffix("_b64") }?.value as? String }
    if b64 == nil, let items = obj["content"] as? [[String: Any]] { b64 = items.first { ($0["type"] as? String) == "image" }?["data"] as? String }
    guard let b64, let image = Data(base64Encoded: b64), let rep = NSBitmapImageRep(data: image), let cg = rep.cgImage else { return nil }
    return grid(cg)
}

func grid(_ image: CGImage) -> [UInt8]? {
    let side = 32
    var pixels = [UInt8](repeating: 0, count: side * side)
    guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .low
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return pixels
}

// One colour (a blank rect): every cell within JPEG noise of the mean.
func uniform(_ g: [UInt8]) -> Bool {
    let mean = g.reduce(0) { $0 + Int($1) } / max(g.count, 1)
    return g.allSatisfy { abs(Int($0) - mean) <= 6 }
}

func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool { zip(a, b).contains { abs(Int($0) - Int($1)) > 10 } }

// Posts the key to the window (without window_id CuaDriver only lists candidate windows and posts nothing). nil when
// no post happened; else whether CuaDriver read the key back from the focused control ("effect": "confirmed").
func cuaKey(_ w: Window) -> Bool? {
    guard let data = cuaCall("press_key", ["pid": Int(w.pid), "window_id": w.id, "delivery_mode": "background",
                                           "key": ProcessInfo.processInfo.environment["LM_KEY"] ?? "a"]),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["candidates"] == nil else { return nil }
    let content = (obj["structuredContent"] as? [String: Any]) ?? obj
    return (content["effect"] as? String) == "confirmed"
}

// MARK: open, quit

var running: NSRunningApplication?, failure: String?

// The app's own arguments after `--`, env=K=V before it.
func appArgs(_ rest: [String]) -> (arguments: [String], env: [String: String]) {
    var env: [String: String] = [:], arguments: [String] = [], afterDash = false
    for a in rest {
        if afterDash { arguments.append(a) } else if a == "--" { afterDash = true }
        else if a.hasPrefix("env="), let eq = a.dropFirst(4).firstIndex(of: "=") {
            env[String(a.dropFirst(4)[..<eq])] = String(a.dropFirst(4)[a.dropFirst(4).index(after: eq)...])
        }
    }
    return (arguments, env)
}

func processStart(_ pid: pid_t) -> Double? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
}

func runningCopy(_ app: URL) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == app.standardizedFileURL.path && $0.processIdentifier > 0 }
}

struct Opened { var requested: Double; var start: Double?; var window: Double?; var win: Window? }

// cmux NEXT's own launch marks, as launch-ready.swift reads them: with LM_MARKS_FIFO set the probe makes that FIFO,
// opens it for reading first (the app's nonblocking open for writing needs a reader), and passes it to the app as
// CMUX_NEXT_LAUNCH_MARKS_PATH. Each line is "NAME MS" (ms since the process started); the first of each name is kept.
// The row's `marks` are as the app wrote them (launch-ready's `marks`), so mac_cold and restart_to_chat read the same
// marks from either harness; `marks_from_request` adds proc_start, the harness's own clock.
var appMarks: [String: Double] = [:], marksPending = Data(), marksSource: DispatchSourceRead?, marksHold: Int32 = -1
func startMarks() -> String? {
    guard let fifo = ProcessInfo.processInfo.environment["LM_MARKS_FIFO"], !fifo.isEmpty else { return nil }
    unlink(fifo)
    guard mkfifo(fifo, 0o600) == 0 else { return nil }
    let fd = Darwin.open(fifo, O_RDONLY | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    // A writer of our own held open, so the app closing its end is no EOF that fires the read source forever.
    marksHold = Darwin.open(fifo, O_WRONLY | O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return }
        marksPending.append(contentsOf: buffer[0..<count])
        while let newline = marksPending.firstIndex(of: 10) {
            let line = String(decoding: marksPending[marksPending.startIndex..<newline], as: UTF8.self)
            marksPending.removeSubrange(marksPending.startIndex...newline)
            let parts = line.split(separator: " ")
            if parts.count >= 2, let ms = Double(parts[parts.count - 1]) {
                let name = parts[0..<(parts.count - 1)].joined(separator: " ")
                if appMarks[name] == nil { appMarks[name] = ms }
            }
        }
    }
    source.resume()
    marksSource = source
    return fifo
}

func open(_ app: URL, _ rest: [String]) -> Opened {
    var (arguments, env) = appArgs(rest)
    if let fifo = startMarks() { env["CMUX_NEXT_LAUNCH_MARKS_PATH"] = fifo }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.arguments = arguments
    if !env.isEmpty { configuration.environment = env }
    let requested = now()
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { app, error in
        DispatchQueue.main.async { if let error { failure = "open: \(error.localizedDescription)" }; if running == nil { running = app } }
    }
    var o = Opened(requested: requested), members: Set<pid_t> = [], lastTree = 0.0
    spin {
        if running == nil { running = runningCopy(app) }
        if let pid = running?.processIdentifier, pid > 0 {
            if o.start == nil { o.start = processStart(pid); members = [pid] }
            // The tree is a full process walk: every 100 ms; the window check every pass (<= 4 ms).
            if now() - lastTree > 100 { members = Set(tree(pid)); lastTree = now() }
            if let w = treeWindow(members) { o.window = now(); o.win = w }
        }
        return failure != nil || o.window != nil || now() - requested > 60_000
    }
    return o
}

// Cmd-Q's way (terminate), SIGTERM after 20 s, SIGKILL after 10 more; then every process left in its tree.
func quit(_ pid: pid_t) -> String {
    let members = tree(pid)
    var how = "terminate"
    running?.terminate()
    let sent = now()
    spin { kill(pid, 0) != 0 || now() - sent > 20_000 }
    if kill(pid, 0) == 0 {
        kill(pid, SIGTERM); how = "sigterm"
        let t = now(); spin { kill(pid, 0) != 0 || now() - t > 10_000 }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL); how = "sigkill" }
    }
    // Helpers of this instance (descendants) still up 5 s later; XPC services launchd owns are left to it.
    let t = now(); spin { members.allSatisfy { kill($0, 0) != 0 || parent($0) == 1 } || now() - t > 5000 }
    for m in members where m != pid && kill(m, 0) == 0 && parent(m) == pid { kill(m, SIGKILL) }
    return how
}

// MARK: modes

switch args[1] {
case "grants":
    emit("LM-GRANTS", grants())

case "evict":
    guard args.count >= 3 else { usage() }
    var before = 0, after = 0, pages = 0, files = 0
    let page = Int(getpagesize())
    let walker = FileManager.default.enumerator(atPath: args[2])
    while let rel = walker?.nextObject() as? String {
        let path = (args[2] as NSString).appendingPathComponent(rel)
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else { continue }
        let fd = Darwin.open(path, O_RDONLY); guard fd >= 0 else { continue }
        defer { close(fd) }
        let size = Int(st.st_size)
        guard let base = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), base != UnsafeMutableRawPointer(bitPattern: -1) else { continue }
        let n = (size + page - 1) / page
        var vec = [CChar](repeating: 0, count: n)
        func count() -> Int { mincore(base, size, &vec) == 0 ? vec.reduce(0) { $0 + (($1 & 1) != 0 ? 1 : 0) } : 0 }
        before += count()
        msync(base, size, MS_INVALIDATE)
        after += count()
        pages += n; files += 1
        munmap(base, size)
    }
    emit("LM-EVICT", ["files": files, "pages": pages, "resident_before": before, "resident_after": after])

case "run", "growth":
    guard args.count >= 5, let amount = Double(args[4]) else { usage() }
    let app = URL(fileURLWithPath: args[2]), label = args[3], rest = Array(args.dropFirst(5))
    if let other = runningCopy(app) { emit("LM-RUN", ["label": label, "error": "already running (pid \(other.processIdentifier)): not ours to quit"]); exit(1) }
    let g = grants()
    let o = open(app, rest)
    let pid = running?.processIdentifier ?? 0
    let since = { (t: Double?) -> Any in json(t.map { round1($0 - o.requested) }) }
    var row: [String: Any] = ["label": label, "app": app.path, "pid": Int(pid), "proc_start": since(o.start),
                              "window_on_screen": since(o.window), "grants": g]
    if let failure { row["error"] = failure } else if o.window == nil { row["error"] = "no window in 60 s" }
    if args[1] == "growth" {
        guard pid > 0, o.window != nil else { emit("LM-GROWTH", row); exit(1) }
        emit("LM-GROWTH", row.merging(["minute": 0], uniquingKeysWith: { $1 }).merging(fields(sample(pid)), uniquingKeysWith: { $1 }))
        var last = sample(pid), lastAt = now()
        for minute in 1...max(1, Int(amount)) {
            pause(60_000)
            guard kill(pid, 0) == 0 else { emit("LM-GROWTH", ["label": label, "minute": minute, "error": "app exited"]); exit(1) }
            let u = sample(pid), at = now()
            var line = fields(u)
            line["label"] = label; line["minute"] = minute
            line["cpu_pct"] = round1((u.cpuMs - last.cpuMs) / (at - lastAt) * 100)
            line["wakeups_per_s"] = round1(Double(u.wakeups - last.wakeups) / ((at - lastAt) / 1000))
            line["disk_read_mb_per_min"] = round1(u.read - last.read); line["disk_written_mb_per_min"] = round1(u.written - last.written)
            emit("LM-GROWTH", line)
            last = u; lastAt = at
        }
        row["quit"] = quit(pid)
        exit(0)
    }
    // first_visible_frame and interactive.
    var frameAt: Double?, frameSource = "window", frameRes: Double?
    var interactiveAt: Double?, blocker: String?, rounds = 0, interactiveRes: Double?, evidence: String?
    let cuaOK = (g["cuadriver"] as? Bool) == true
    if let w = o.win, pid > 0 {
        if cuaOK {
            frameSource = "cuadriver"
            var prev: [UInt8]?, stableSince: [UInt8]?
            let deadline = now() + 30_000
            // The first non-uniform capture.
            while now() < deadline, frameAt == nil {
                let t0 = now()
                guard let g = cuaCapture(w) else { pause(16); continue }
                if !uniform(g) { frameAt = now(); frameRes = round1(now() - t0); prev = g }
            }
            if frameAt == nil { frameSource = "window"; blocker = "no capture of the window through CuaDriver" }
            // Keys: once two captures in a row agree (the window holds still), post a letter; accepted when the next
            // capture differs. Pixels moving on their own reset the wait for stillness.
            while let p = prev, now() < deadline, interactiveAt == nil {
                pause(16)
                guard let g = cuaCapture(w) else { continue }
                if differs(g, p) { prev = g; stableSince = nil; continue }
                stableSince = g
                let pressed = now()
                guard let confirmed = cuaKey(w) else { blocker = "CuaDriver press_key failed"; break }
                rounds += 1
                if confirmed { interactiveAt = pressed; interactiveRes = round1(now() - pressed); evidence = "ax_readback"; break }
                guard let after = cuaCapture(w) else { continue }
                if differs(after, stableSince!) {
                    interactiveAt = pressed; interactiveRes = round1(now() - pressed); evidence = "pixels"; break
                }
                prev = after
            }
            if interactiveAt == nil, blocker == nil { blocker = rounds == 0 ? "window never held still for 30 s" : "no key changed the window in 30 s (\(rounds) keys)" }
        } else {
            blocker = "no input route: the probe has no post-event or capture grant and no CuaDriver"
        }
    }
    row["first_visible_frame"] = since(frameAt ?? o.window)
    row["frame_source"] = frameSource
    row["frame_resolution_ms"] = json(frameRes)
    row["interactive"] = since(interactiveAt)
    row["interactive_blocker"] = json(interactiveAt == nil ? (blocker ?? "no window") : nil)
    row["interactive_rounds"] = rounds
    row["interactive_evidence"] = json(evidence)
    row["interactive_resolution_ms"] = json(interactiveRes)
    if pid > 0, kill(pid, 0) == 0 {
        if interactiveAt == nil, let w = o.window { spin { now() - w >= 2000 } }
        let first = sample(pid), firstAt = now()
        row["at_interactive"] = fields(first)
        // The settle ends early only when the app quit on its own (launch-matrix.sh's seed: the seed quits it).
        let settleEnd = now() + amount * 1000
        spin { now() >= settleEnd || kill(pid, 0) != 0 }
        if kill(pid, 0) != 0 { row["exited_during_settle"] = true }
        let settled = sample(pid), settledAt = now()
        var s = fields(settled)
        s["idle_cpu_pct"] = round1((settled.cpuMs - first.cpuMs) / (settledAt - firstAt) * 100)
        s["idle_wakeups_per_s"] = round1(Double(settled.wakeups - first.wakeups) / ((settledAt - firstAt) / 1000))
        s["settle_s"] = amount
        row["settled"] = s
        row["quit"] = quit(pid)
    }
    if marksSource != nil {
        row["marks"] = appMarks
        if let start = o.start { row["marks_from_request"] = appMarks.mapValues { round1($0 + start - o.requested) } }
    }
    emit("LM-RUN", row)
    exit(row["error"] == nil ? 0 : 1)

default:
    usage()
}
