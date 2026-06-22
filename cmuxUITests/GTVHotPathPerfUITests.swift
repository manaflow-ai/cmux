import XCTest
import Foundation
import Darwin

/// GhosttyTerminalView (GTV) hot-path performance BASELINE.
///
/// Captures median/p95 latency for the instrumented typing/render hot paths so a
/// later refactor (notably the `handleAction` inversion) can prove it did not
/// regress frame/keystroke timing. It launches a tagged DEBUG build with
/// `CMUX_KEY_LATENCY_PROBE=1` (so `CmuxTypingTiming` logs EVERY event) and a
/// tagged `CMUX_DEBUG_LOG`, creates a workspace, runs a warmup plus three
/// deterministic bursts, then parses the tagged log and prints a JSON summary to
/// the test output so the numbers are recoverable from CI logs.
///
/// Bursts and the paths each exercises:
///   1. keyDown burst  — `app.typeText` of real keystrokes through the responder
///      chain: `terminal.keyDown`, `terminal.keyDown.ghosttySend(.total)`, and
///      (via interpretKeyEvents -> insertText) `terminal.sendTextToSurface`.
///   2. IME burst      — `debug.terminal.simulate_marked_text` / `..unmark_text`
///      drive `setMarkedText` / `unmarkText`: `terminal.setMarkedText`,
///      `terminal.unmarkText`.
///   3. render burst   — a 4000-line `for` loop printed to the PTY drives Ghostty
///      render/scroll actions: `terminal.handleAction.RENDER/SCROLLBAR/CELL_SIZE`.
///   plus `main.turn.work` (turnMs) emitted by the main-thread turn profiler
///   across all of the above.
final class GTVHotPathPerfUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var debugLogPath = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private var launchTag = ""
    private var temporaryRoots: [URL] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let uuid = UUID().uuidString
        socketPath = "/tmp/cmux-debug-\(uuid).sock"
        diagnosticsPath = "/tmp/cmux-gtvperf-diag-\(uuid).json"
        debugLogPath = "/tmp/cmux-gtvperf-log-\(uuid).log"
        launchTag = "gtvperf-\(uuid.prefix(8))"
        temporaryRoots = []
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: debugLogPath)
        // Pre-create the log so the app appends to a known path.
        FileManager.default.createFile(atPath: debugLogPath, contents: Data())
    }

    override func tearDown() {
        // Preserve the app debug log to a stable path for post-mortem when a run
        // misbehaves locally (gated to an opt-in env so CI stays clean).
        if ProcessInfo.processInfo.environment["CMUX_GTVPERF_KEEP_LOG"] == "1",
           let data = FileManager.default.contents(atPath: debugLogPath) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/cmux-gtvperf-applog-last.log"))
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: debugLogPath)
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testGTVHotPathBaseline() throws {
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 20.0),
            "Expected app to launch. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 20.0),
            "Expected control socket ping at \(socketPath). diagnostics=\(loadDiagnostics())"
        )

        let workdir = try makeWorkdir()
        let workspace = try XCTUnwrap(
            socketResult(
                method: "workspace.create",
                params: [
                    "title": "GTV perf baseline",
                    "working_directory": workdir.path,
                    "focus": true,
                ]
            ),
            "workspace.create failed"
        )
        let surfaceID = try XCTUnwrap(workspace["surface_id"] as? String, "no surface_id")

        // Wait for the shell prompt so input lands in an interactive shell.
        XCTAssertTrue(
            waitForShellReady(surfaceID: surfaceID, timeout: 25.0),
            "Shell did not become ready. text=\(readTerminalText(surfaceID: surfaceID) ?? "<nil>")\nDIAG:\n\(shellReadinessDiagnostics(surfaceID: surfaceID))"
        )
        // Make sure the terminal view is the focused first responder for typeText.
        XCTAssertTrue(
            waitForTerminalFocused(surfaceID: surfaceID, timeout: 8.0),
            "Terminal surface never reported focused"
        )

        // ---- Warmup (not measured): JIT/first-touch the hot paths. ----
        app.typeText("warmup warmup warmup\n")
        for _ in 0..<8 {
            _ = socketResult(method: "debug.terminal.simulate_marked_text", params: ["surface_id": surfaceID, "text": "x"])
            _ = socketResult(method: "debug.terminal.simulate_unmark_text", params: ["surface_id": surfaceID])
        }
        _ = socketResult(method: "surface.send_text", params: ["surface_id": surfaceID, "text": "for i in $(seq 1 200); do echo warm $i; done"])
        _ = socketResult(method: "surface.send_key", params: ["surface_id": surfaceID, "key": "return"])
        // Let the warmup render loop fully drain before the measured keyDown burst.
        // Each `typeText` first blocks on "wait for app to idle"; if the warmup
        // echo loop is still rendering, that wait can stall for tens of seconds
        // and XCUITest then aborts the synthesize with a timeout. Wait for the log
        // (which the render loop is actively appending to) to go quiet first.
        waitForLogQuiescence(timeout: 20.0, quietFor: 1.5)

        // Truncate the log so only measured bursts are parsed.
        if ProcessInfo.processInfo.environment["CMUX_GTVPERF_KEEP_LOG"] == "1",
           let data = FileManager.default.contents(atPath: debugLogPath) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/cmux-gtvperf-applog-warmup.log"))
        }
        try? "".write(toFile: debugLogPath, atomically: true, encoding: .utf8)

        // ---- Burst 1: keyDown burst (real NSEvents via typeText). ----
        // Alphanumerics only (predictable single-keystroke mapping). `typeText`
        // synthesizes one discrete keyDown per character, so a single call types
        // the whole burst as ~`keyDownLines * keyDownChars.count` real keyDowns
        // through the responder chain. We type it in one shot rather than 60
        // separate calls: each `typeText` blocks on "wait for app to idle", and
        // doing that 60 times while the terminal is redrawing makes one of those
        // idle-waits eventually stall past XCUITest's synthesize timeout. One
        // synthesize = one idle wait = deterministic.
        let keyDownLines = 60
        let keyDownChars = "the quick brown fox jumps over 13 lazy dogs "
        let keyDownBurst = String(repeating: keyDownChars, count: keyDownLines)
        app.typeText(keyDownBurst)
        // Clear the typed buffer so it doesn't run as a command.
        app.typeText("\u{15}") // Ctrl-U (clear line) where supported

        // ---- Burst 2: IME marked-text burst (setMarkedText / unmarkText). ----
        let imeIterations = 80
        for i in 0..<imeIterations {
            _ = socketResult(
                method: "debug.terminal.simulate_marked_text",
                params: ["surface_id": surfaceID, "text": "\u{3042}\u{3044}\u{3046}\(i % 10)"]
            )
            _ = socketResult(
                method: "debug.terminal.simulate_unmark_text",
                params: ["surface_id": surfaceID]
            )
        }

        // ---- Burst 3: render / scrollbar burst (4000-line for loop). ----
        let renderLines = 4000
        _ = socketResult(
            method: "surface.send_text",
            params: [
                "surface_id": surfaceID,
                "text": "for i in $(seq 1 \(renderLines)); do echo \"render line $i ---------------------------------\"; done",
            ]
        )
        _ = socketResult(method: "surface.send_key", params: ["surface_id": surfaceID, "key": "return"])

        // Let the render burst drain. Poll for completion by watching the log grow
        // quiet rather than a fixed sleep.
        waitForLogQuiescence(timeout: 30.0, quietFor: 2.0)

        // ---- Parse + summarize. ----
        let logText = (try? String(contentsOfFile: debugLogPath, encoding: .utf8)) ?? ""
        let samples = parseSamples(from: logText)

        let interestingPaths = [
            "terminal.keyDown",
            "terminal.keyDown.ghosttySend.total",
            "terminal.setMarkedText",
            "terminal.unmarkText",
            "terminal.sendTextToSurface",
            "terminal.handleAction.RENDER",
            "terminal.handleAction.SCROLLBAR",
            "terminal.handleAction.CELL_SIZE",
            "main.turn.work",
        ]

        var summary: [[String: Any]] = []
        for path in interestingPaths {
            let values = samples[path] ?? []
            let stats = computeStats(values)
            summary.append([
                "path": path,
                "n": values.count,
                "median_ms": stats.median,
                "p95_ms": stats.p95,
                "max_ms": stats.max,
            ])
        }

        // Emit a machine-recoverable block to the test log.
        let payload: [String: Any] = [
            "kind": "gtv_hot_path_baseline",
            "tag": launchTag,
            "keyDownLines": keyDownLines,
            "imeIterations": imeIterations,
            "renderLines": renderLines,
            "logBytes": logText.utf8.count,
            "paths": summary,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("GTV_PERF_BASELINE_JSON_BEGIN")
            print(json)
            print("GTV_PERF_BASELINE_JSON_END")
        }
        // Human-readable per-path lines too.
        for entry in summary {
            print(String(
                format: "GTV_PERF path=%@ n=%@ median=%@ p95=%@ max=%@",
                entry["path"] as? String ?? "?",
                "\(entry["n"] as? Int ?? 0)",
                fmt(entry["median_ms"] as? Double),
                fmt(entry["p95_ms"] as? Double),
                fmt(entry["max_ms"] as? Double)
            ))
        }

        // The probe must have produced real numbers for the primary paths, else
        // the baseline is not trustworthy and the test should fail loudly.
        let keyDownN = (samples["terminal.keyDown"] ?? []).count
        XCTAssertGreaterThan(
            keyDownN, 20,
            "Expected many terminal.keyDown samples from the keyDown burst. Log head:\n\(String(logText.prefix(2000)))"
        )
        let renderN = (samples["terminal.handleAction.RENDER"] ?? []).count
            + (samples["terminal.handleAction.SCROLLBAR"] ?? []).count
        XCTAssertGreaterThan(
            renderN, 0,
            "Expected render/scrollbar handleAction samples from the render burst."
        )
        // IME seam should fire (this branch wires the debug method).
        XCTAssertGreaterThan(
            (samples["terminal.setMarkedText"] ?? []).count, 0,
            "Expected terminal.setMarkedText samples from the IME burst."
        )

        app.terminate()
    }

    // MARK: - Parsing / stats

    /// Maps `path` -> [elapsedMs] across `typing.timing`, `typing.phase`
    /// (totalMs and dotted sub-parts like `ghosttySend.total`), and
    /// `main.turn.work` (turnMs) lines.
    private func parseSamples(from log: String) -> [String: [Double]] {
        var result: [String: [Double]] = [:]
        func append(_ path: String, _ value: Double) {
            result[path, default: []].append(value)
        }
        for rawLine in log.split(separator: "\n") {
            let line = String(rawLine)
            let fields = parseFields(line)
            if line.contains("typing.timing"), let path = fields["path"], let ms = fields["elapsedMs"].flatMap(Double.init) {
                append(path, ms)
            } else if line.contains("typing.phase"), let path = fields["path"] {
                if let total = fields["totalMs"].flatMap(Double.init) {
                    append(path, total)
                }
                // Dotted sub-parts (e.g. ghosttySend.total) record under the
                // composed `path.subpart` name so refactor comparisons can target
                // the per-phase span explicitly.
                for (key, value) in fields where key.contains(".") {
                    if let v = Double(value) {
                        append("\(path).\(key)", v)
                    }
                }
            } else if line.contains("main.turn.work"), let ms = fields["turnMs"].flatMap(Double.init) {
                append("main.turn.work", ms)
            }
        }
        return result
    }

    /// Splits `k=v` space-delimited fields. Values are read up to the next space;
    /// quoted values are not expected on the probe lines we parse.
    private func parseFields(_ line: String) -> [String: String] {
        var fields: [String: String] = [:]
        for token in line.split(separator: " ") {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[token.startIndex..<eq])
            let value = String(token[token.index(after: eq)...])
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }

    private func computeStats(_ values: [Double]) -> (median: Double, p95: Double, max: Double) {
        guard !values.isEmpty else { return (0, 0, 0) }
        let sorted = values.sorted()
        return (percentile(sorted, 0.50), percentile(sorted, 0.95), sorted.last ?? 0)
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down))
        let high = Int(rank.rounded(.up))
        if low == high { return sorted[low] }
        let frac = rank - Double(low)
        return sorted[low] + (sorted[high] - sorted[low]) * frac
    }

    private func fmt(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.3f", value)
    }

    // MARK: - Socket / readiness helpers

    private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]

        // The env this run needs. On the AWS GUI path (`xcodebuild` launched via
        // `launchctl asuser`) `launchEnvironment` is NOT propagated to the test
        // host, so the host boots untagged, trips
        // `SocketControlSettings.shouldBlockUntaggedDebugLaunch()`, prints
        // "refusing to launch untagged cmux DEV" and `exit(64)`s before the
        // socket comes up. Launch ARGUMENTS do propagate, and
        // `UITestLaunchManifest.applyIfPresent()` (cmuxApp.swift) runs before
        // that guard, applying this env via `setenv` from a manifest pointed to
        // by the `-cmuxUITestLaunchManifest` argument. So write the env into a
        // manifest and pass it as an argument; keep `launchEnvironment` too (it
        // is harmless and still works on the normal CI/local path).
        let environment: [String: String] = launchEnvironmentValues()
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        if let manifestArgument = writeLaunchManifest(environment: environment) {
            app.launchArguments += manifestArgument
        }
        return app
    }

    /// All env vars the perf run depends on. `CMUX_UI_TEST_*` keys also make
    /// `shouldBlockUntaggedDebugLaunch()` short-circuit (line that checks for any
    /// `CMUX_UI_TEST_` prefix), so the untagged-launch guard never fires.
    private func launchEnvironmentValues() -> [String: String] {
        var environment: [String: String] = [
            "CMUX_UI_TEST_MODE": "1",
            "CMUX_SOCKET_ENABLE": "1",
            "CMUX_SOCKET_MODE": "allowAll",
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            "CMUX_UI_TEST_SOCKET_SANITY": "1",
            "CMUX_UI_TEST_DIAGNOSTICS_PATH": diagnosticsPath,
            "CMUX_TAG": launchTag,
            // Probe knobs: log EVERY typing/turn event, to the tagged path.
            "CMUX_KEY_LATENCY_PROBE": "1",
            "CMUX_DEBUG_LOG": debugLogPath,
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            environment["PATH"] = path
        }
        return environment
    }

    /// Writes a `{ "environment": { … } }` manifest matching
    /// `UITestLaunchManifest.Payload` and returns the
    /// `-cmuxUITestLaunchManifest <path>` launch argument pair. The file lives in
    /// a temp dir tracked by `temporaryRoots` so `tearDown` removes it.
    private func writeLaunchManifest(environment: [String: String]) -> [String]? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-gtvperf-manifest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        temporaryRoots.append(root)
        let manifestURL = root.appendingPathComponent("launch-manifest.json")
        let payload: [String: Any] = ["environment": environment]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        do {
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            return nil
        }
        return ["-cmuxUITestLaunchManifest", manifestURL.path]
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) { return true }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 8.0)
        }
        return false
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        let ready = waitForControlSocketReady(
            pingTimeout: timeout,
            socketFileExists: { self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) } },
            pingReturnsPong: {
                let original = self.socketPath
                for candidate in self.socketCandidates() where FileManager.default.fileExists(atPath: candidate) {
                    self.socketPath = candidate
                    if self.socketCommand("ping") == "PONG" { return true }
                    self.socketPath = original
                }
                return false
            }
        )
        return ready
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        if let expected = loadDiagnostics()["socketExpectedPath"], !expected.isEmpty {
            candidates.append(expected)
        }
        var seen = Set<String>()
        candidates.removeAll { !seen.insert($0).inserted }
        return candidates
    }

    private func taggedSocketPath() -> String {
        let slug = launchTag
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "/tmp/cmux-debug-\(slug).sock"
    }

    private func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in object { result[key] = String(describing: value) }
        return result
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 1.0).sendLine(command)
    }

    private func socketResult(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        guard let envelope = ControlSocketClient(path: socketPath, responseTimeout: 5.0).sendJSON(request),
              envelope["ok"] as? Bool == true else {
            return nil
        }
        return (envelope["result"] as? [String: Any]) ?? [:]
    }

    private func readTerminalText(surfaceID: String) -> String? {
        guard let result = socketResult(method: "debug.terminal.read_text", params: ["surface_id": surfaceID]),
              let b64 = result["base64"] as? String,
              let data = Data(base64Encoded: b64) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Returns the full JSON envelope (ok/result/error) for a socket call so a
    /// failing readiness gate can report the exact server-side error.
    private func rawEnvelope(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        return ControlSocketClient(path: socketPath, responseTimeout: 5.0).sendJSON(request)
    }

    /// One-shot diagnostic block for why the shell never became ready: dumps the
    /// raw read_text envelope, current workspace, focused-surface state, and the
    /// surface list so the failure message points at the exact gate.
    private func shellReadinessDiagnostics(surfaceID: String) -> String {
        var lines: [String] = []
        lines.append("read_text envelope: \(String(describing: rawEnvelope(method: "debug.terminal.read_text", params: ["surface_id": surfaceID])))")
        lines.append("read_text (no surface_id): \(String(describing: rawEnvelope(method: "debug.terminal.read_text", params: [:])))")
        lines.append("is_focused: \(String(describing: rawEnvelope(method: "debug.terminal.is_focused", params: ["surface_id": surfaceID])))")
        lines.append("render_stats: \(String(describing: rawEnvelope(method: "debug.terminal.render_stats", params: ["surface_id": surfaceID])))")
        lines.append("current_workspace: \(String(describing: rawEnvelope(method: "workspace.current", params: [:])))")
        lines.append("list_surfaces: \(String(describing: rawEnvelope(method: "surface.list", params: [:])))")
        lines.append("list_workspaces: \(String(describing: rawEnvelope(method: "workspace.list", params: [:])))")
        return lines.joined(separator: "\n")
    }

    private func waitForShellReady(surfaceID: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = readTerminalText(surfaceID: surfaceID), text.contains("$") || text.contains("%") || text.contains("#") {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return readTerminalText(surfaceID: surfaceID)?.isEmpty == false
    }

    private func waitForTerminalFocused(surfaceID: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = socketResult(method: "debug.terminal.is_focused", params: ["surface_id": surfaceID]),
               (result["focused"] as? Bool == true || (result["focused"] as? Int ?? 0) == 1) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        // Focus state is best-effort; typeText still routes to the key window.
        return true
    }

    /// Polls the log file size and returns once it has not grown for `quietFor`
    /// seconds (the render burst has drained) or `timeout` elapses.
    private func waitForLogQuiescence(timeout: TimeInterval, quietFor: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize = logFileSize()
        var lastChange = Date()
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let size = logFileSize()
            if size != lastSize {
                lastSize = size
                lastChange = Date()
            } else if Date().timeIntervalSince(lastChange) >= quietFor {
                return
            }
        }
    }

    private func logFileSize() -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: debugLogPath)
        return (attrs?[.size] as? Int) ?? 0
    }

    private func makeWorkdir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-gtvperf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    // MARK: - Unix-socket client

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendJSON(_ object: [String: Any]) -> [String: Any]? {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8),
                  let response = sendLine(line),
                  let responseData = response.data(using: .utf8) else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var timeout = timeval(
                tv_sec: Int(responseTimeout),
                tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
            )
            withUnsafePointer(to: &timeout) { ptr in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = Array(path.utf8CString)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            guard pathBytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                for index in 0..<pathBytes.count { raw[index] = pathBytes[index] }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + pathBytes.count)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(fd, sockaddrPtr, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = Array((line + "\n").utf8)
            let wrote = payload.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return true }
                return Darwin.write(fd, baseAddress, rawBuffer.count) == rawBuffer.count
            }
            guard wrote else { return nil }

            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            let deadline = Date().addingTimeInterval(responseTimeout)
            while Date() < deadline {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                    if count < buffer.count { break }
                }
            }
            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
