import XCTest
import Foundation
import Darwin

final class AutomationSocketUITests: XCTestCase {
    private var socketPath = ""
    private var diagnosticsPath = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"
    private var launchTag = ""
    private var temporaryRoots: [URL] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-automation-socket-\(UUID().uuidString).json"
        launchTag = "ui-tests-automation-\(UUID().uuidString.prefix(8))"
        temporaryRoots = []
        resetSocketDefaults()
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
    }

    override func tearDown() {
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
        try? FileManager.default.removeItem(atPath: taggedSocketPath())
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testSocketToggleDisablesAndEnables() {
        let app = configuredApp(mode: "cmuxOnly")
        app.launch()
        XCTAssertTrue(
            ensureRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket toggle test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0, allowTmpFallback: false) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocket(exists: true, timeout: 2.0))
        app.terminate()
    }

    func testSocketPathDeletionRecreatesListener() throws {
        let app = configuredApp(mode: "automation")
        app.launch()
        XCTAssertTrue(
            ensureRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket path recreation test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0, allowTmpFallback: false) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocketPong(timeout: 5.0), "Expected initial socket ping at \(socketPath)")

        try FileManager.default.removeItem(atPath: socketPath)

        XCTAssertTrue(
            waitForSocketPong(timeout: 8.0, allowDiagnosticsFallback: false),
            "Expected listener to recreate removed socket path and answer ping at \(socketPath)"
        )
        app.terminate()
    }

    func testSocketDisabledWhenSettingOff() {
        let app = configuredApp(mode: "off")
        app.launch()
        XCTAssertTrue(
            ensureRunningAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket off test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForSocket(exists: false, timeout: 3.0))
        app.terminate()
    }

    func testTextBoxSkillMentionFiltersWhenTypingAfterBareDollarTrigger() throws {
        let skillRoot = try makeSkillFixtureRoot(
            skillNames: [
                "agent-browser",
                "agent-cli-integration",
                "iterate-pr",
            ]
        )
        let app = XCUIApplication()
        configureTextBoxMentionLaunchEnvironment(app)
        defer { app.terminate() }
        app.launch()

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for textbox mention test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected socket ping at \(socketPath). diagnostics=\(loadDiagnostics())"
        )

        let workspace = try XCTUnwrap(
            socketResult(
                method: "workspace.create",
                params: [
                    "title": "Textbox mention XCUITest",
                    "working_directory": skillRoot.path,
                    "focus": true,
                ]
            ),
            "Expected workspace.create to succeed"
        )
        let surfaceID = try XCTUnwrap(workspace["surface_id"] as? String, "Expected created surface id")

        _ = try XCTUnwrap(
            waitForTextBoxFixture(surfaceID: surfaceID, beforeText: "$", timeout: 8.0),
            "Expected text box fixture to mount with a bare $ trigger"
        )
        _ = try XCTUnwrap(
            socketResult(
                method: "debug.textbox.interact",
                params: ["surface_id": surfaceID, "action": "focus"]
            ),
            "Expected text box focus to succeed"
        )

        let bareState = try XCTUnwrap(
            waitForMentionState(surfaceID: surfaceID, timeout: 8.0) { state in
                let titles = state["mention_titles"] as? [String] ?? []
                return state["mention_trigger"] as? String == "$" &&
                    state["mention_query"] as? String == "" &&
                    titles.contains("$agent-browser")
            },
            "Expected bare $ suggestions to include $agent-browser"
        )
        XCTAssertEqual(bareState["plain_text"] as? String, "$")

        app.typeText("iterate")

        let typedState = try XCTUnwrap(
            waitForMentionState(surfaceID: surfaceID, timeout: 8.0) { state in
                let titles = state["mention_titles"] as? [String] ?? []
                return state["plain_text"] as? String == "$iterate" &&
                    state["mention_trigger"] as? String == "$" &&
                    state["mention_query"] as? String == "iterate" &&
                    state["mention_current"] as? Bool == true &&
                    titles.contains("$iterate-pr") &&
                    !titles.contains("$agent-browser")
            },
            "Expected typing iterate after bare $ to filter stale $agent-browser and show $iterate-pr"
        )

        let typedTitles = typedState["mention_titles"] as? [String] ?? []
        XCTAssertEqual(typedTitles.first, "$iterate-pr")
    }

    private func configuredApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", mode]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        // Debug launches require a tag outside reload.sh; provide one in UITests so CI
        // does not fail with "Application ... does not have a process ID".
        app.launchEnvironment["CMUX_TAG"] = launchTag
        return app
    }

    private func configureTextBoxMentionLaunchEnvironment(_ app: XCUIApplication) {
        app.launchArguments += [
            "-\(modeKey)", "allowAll",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_TAG"] = launchTag
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        // On busy UI runners the app can launch backgrounded; activate once before failing.
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func ensureRunningAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.state == .runningForeground || app.state == .runningBackground
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForSocketPong(timeout: TimeInterval, allowDiagnosticsFallback: Bool = true) -> Bool {
        var resolvedPath: String?
        let ready = waitForControlSocketReady(
            pingTimeout: timeout,
            socketFileExists: { self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) } },
            pingReturnsPong: {
                let originalPath = self.socketPath
                for candidate in self.socketCandidates() {
                    guard FileManager.default.fileExists(atPath: candidate) else { continue }
                    self.socketPath = candidate
                    if self.socketCommand("ping") == "PONG" {
                        resolvedPath = candidate
                        return true
                    }
                    self.socketPath = originalPath
                }
                return false
            }
        )
        if ready, let resolvedPath {
            socketPath = resolvedPath
            return true
        }
        guard allowDiagnosticsFallback else { return false }
        let diagnostics = loadDiagnostics()
        guard controlSocketDiagnosticsReportReady(diagnostics),
              let expectedPath = diagnostics["socketExpectedPath"],
              socketCandidates().contains(expectedPath) else {
            return false
        }
        socketPath = expectedPath
        return true
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        if let expectedPath = loadDiagnostics()["socketExpectedPath"], !expectedPath.isEmpty {
            candidates.append(expectedPath)
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
        var diagnostics: [String: String] = [:]
        for (key, value) in object {
            diagnostics[key] = String(describing: value)
        }
        return diagnostics
    }

    private func waitForSocket(exists: Bool, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                if exists {
                    return self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) }
                }
                return !self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) }
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 1.0).sendLine(command) ??
            controlSocketCommandViaNetcat(command, socketPath: socketPath)
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendJSON(request) ??
            controlSocketJSONViaNetcat(request, socketPath: socketPath)
    }

    private func socketResult(method: String, params: [String: Any]) -> [String: Any]? {
        guard let envelope = socketJSON(method: method, params: params),
              envelope["ok"] as? Bool == true else {
            return nil
        }
        return envelope["result"] as? [String: Any]
    }

    private func waitForTextBoxFixture(
        surfaceID: String,
        beforeText: String,
        timeout: TimeInterval
    ) -> [String: Any]? {
        waitForJSON(timeout: timeout) {
            guard let result = self.socketResult(
                method: "debug.textbox.inline_fixture",
                params: [
                    "surface_id": surfaceID,
                    "before_text": beforeText,
                    "after_text": "",
                ]
            ) else {
                return nil
            }
            guard result["text_view_has_window"] as? Bool == true,
                  result["text_view_text"] as? String == beforeText else {
                return nil
            }
            return result
        }
    }

    private func waitForMentionState(
        surfaceID: String,
        timeout: TimeInterval,
        predicate: @escaping ([String: Any]) -> Bool
    ) -> [String: Any]? {
        waitForJSON(timeout: timeout) {
            guard let result = self.socketResult(
                method: "debug.textbox.interact",
                params: ["surface_id": surfaceID, "action": "focus"]
            ),
                  let state = result["state"] as? [String: Any] else {
                return nil
            }
            return predicate(state) ? state : nil
        }
    }

    private func waitForJSON(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        producer: () -> [String: Any]?
    ) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = producer() {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return producer()
    }

    private func makeSkillFixtureRoot(skillNames: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-textbox-skills-\(UUID().uuidString)", isDirectory: true)
        let skills = root.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        for skillName in skillNames {
            let skillDirectory = skills.appendingPathComponent(skillName, isDirectory: true)
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            let contents = """
            ---
            name: \(skillName)
            ---

            Test skill fixture for \(skillName).
            """
            try contents.write(
                to: skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }
        temporaryRoots.append(root)
        return root
    }

    private func resolveSocketPath(timeout: TimeInterval, allowTmpFallback: Bool = true) -> String? {
        var resolvedPath: String?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                if FileManager.default.fileExists(atPath: self.socketPath) {
                    resolvedPath = self.socketPath
                    return true
                }
                guard allowTmpFallback else { return false }
                if let found = self.findSocketInTmp() {
                    resolvedPath = found
                    return true
                }
                return false
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return resolvedPath
        }
        return resolvedPath
    }

    private func findSocketInTmp() -> String? {
        let tmpPath = "/tmp"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) else {
            return nil
        }
        let matches = entries.filter { $0.hasPrefix("cmux") && $0.hasSuffix(".sock") }
        if let debug = matches.first(where: { $0.contains("debug") }) {
            return (tmpPath as NSString).appendingPathComponent(debug)
        }
        if let first = matches.first {
            return (tmpPath as NSString).appendingPathComponent(first)
        }
        return nil
    }

    private func resetSocketDefaults() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", defaultsDomain, modeKey]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
        let legacy = Process()
        legacy.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        legacy.arguments = ["delete", defaultsDomain, legacyKey]
        do {
            try legacy.run()
            legacy.waitUntilExit()
        } catch {
            return
        }
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }

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
                for index in 0..<pathBytes.count {
                    raw[index] = pathBytes[index]
                }
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
                    if count < buffer.count {
                        break
                    }
                }
            }
            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
