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
    private var lastTextBoxFixtureResponse = ""
    private var lastMainWindowContextResponse = ""
    private var lastWorkspaceCreateResponse = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-automation-socket-\(UUID().uuidString).json"
        launchTag = "ui-tests-automation-\(UUID().uuidString.prefix(8))"
        temporaryRoots = []
        lastTextBoxFixtureResponse = ""
        lastMainWindowContextResponse = ""
        lastWorkspaceCreateResponse = ""
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
            ensureForegroundAfterLaunch(app, timeout: 12.0),
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
            ensureForegroundAfterLaunch(app, timeout: 12.0),
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
            waitForSocketPong(timeout: 8.0),
            "Expected listener to recreate removed socket path and answer ping at \(socketPath)"
        )
        app.terminate()
    }

    func testSocketDisabledWhenSettingOff() {
        let app = configuredApp(mode: "off")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
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
                "auto-issue",
                "auto-merge",
                "autoreview",
                "iterate-pr",
            ]
        )
        let app = XCUIApplication()
        configureTextBoxMentionLaunchEnvironment(app)
        defer { app.terminate() }
        launchAllowingBackgroundActivation(app)

        XCTAssertTrue(
            waitForRunningApp(app, timeout: 12.0),
            "Expected app to launch for textbox mention test. state=\(app.state.rawValue)"
        )
        XCTAssertTrue(
            waitForSocketPong(timeout: 12.0),
            "Expected socket ping at \(socketPath). diagnostics=\(loadDiagnostics())"
        )

        let windowContext = waitForMainWindowContext(timeout: 12.0)
        let workspace = createTextBoxFixtureWorkspace(
            windowID: windowContext?.windowID,
            workingDirectory: skillRoot.path
        )
        let createdSurfaceID = workspace?["surface_id"] as? String

        let fixture = try XCTUnwrap(
            waitForTextBoxFixture(
                surfaceID: createdSurfaceID,
                beforeText: "$",
                completionRootDirectory: skillRoot.path,
                timeout: 8.0
            ),
            """
            Expected text box fixture to mount with a bare $ trigger.
            window=\(lastMainWindowContextResponse)
            workspace=\(lastWorkspaceCreateResponse)
            fixture=\(lastTextBoxFixtureResponse)
            diagnostics=\(loadDiagnostics())
            """
        )
        let surfaceID = try XCTUnwrap(fixture["surface_id"] as? String, "Expected fixture surface id")
        if let createdSurfaceID {
            XCTAssertEqual(surfaceID, createdSurfaceID)
        }
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
        _ = try XCTUnwrap(
            waitForMentionRows(in: app, timeout: 8.0) { rows in
                rows.contains { $0.contains("$agent-browser") }
            },
            "Expected bare $ popover rows to include $agent-browser. rows=\(mentionPopoverRowTitles(in: app))"
        )

        _ = try XCTUnwrap(
            socketResult(
                method: "debug.textbox.interact",
                params: ["surface_id": surfaceID, "action": "insert_text:autore"]
            ),
            "Expected textbox debug insert to succeed"
        )

        let typedState = try XCTUnwrap(
            waitForMentionState(surfaceID: surfaceID, timeout: 8.0) { state in
                let titles = state["mention_titles"] as? [String] ?? []
                return state["plain_text"] as? String == "$autore" &&
                    state["mention_trigger"] as? String == "$" &&
                    state["mention_query"] as? String == "autore" &&
                    state["mention_current"] as? Bool == true &&
                    titles.contains("$autoreview") &&
                    !titles.contains("$agent-browser")
            },
            "Expected typing autore after bare $ to filter stale $agent-browser and show $autoreview"
        )

        let typedTitles = typedState["mention_titles"] as? [String] ?? []
        XCTAssertEqual(typedTitles.first, "$autoreview")
        let typedRows = try XCTUnwrap(
            waitForMentionRows(in: app, timeout: 8.0) { rows in
                rows.first?.contains("$autoreview") == true &&
                    !rows.contains { $0.contains("$agent-browser") }
            },
            "Expected visible popover rows for $autore to hide stale $agent-browser. rows=\(mentionPopoverRowTitles(in: app)) state=\(typedState)"
        )
        XCTAssertTrue(typedRows.first?.contains("$autoreview") == true)
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

    private func launchAllowingBackgroundActivation(_ app: XCUIApplication) {
        // Headless cloud runners can launch the app but fail WindowServer activation.
        // The socket and accessibility APIs used below still work in background.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless UI runners", options: options) {
            app.launch()
        }
    }

    private func waitForRunningApp(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            return true
        }
        return false
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        var resolvedPath: String?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
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
            },
            object: NSObject()
        )
        let completed = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        if let resolvedPath {
            socketPath = resolvedPath
        }
        if completed {
            return true
        }
        let diagnostics = loadDiagnostics()
        if diagnostics["socketReady"] == "1",
           diagnostics["socketPingResponse"] == "PONG",
           let expectedPath = diagnostics["socketExpectedPath"],
           !expectedPath.isEmpty,
           FileManager.default.fileExists(atPath: expectedPath) {
            socketPath = expectedPath
            return true
        }
        return completed
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
        ControlSocketClient(path: socketPath, responseTimeout: 1.0).sendLine(command)
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        return ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendJSON(request)
    }

    private func socketResult(method: String, params: [String: Any]) -> [String: Any]? {
        guard let envelope = socketJSON(method: method, params: params),
              envelope["ok"] as? Bool == true else {
            return nil
        }
        return envelope["result"] as? [String: Any]
    }

    private func waitForMainWindowContext(timeout: TimeInterval) -> (windowID: String, surfaceID: String?)? {
        waitForJSON(timeout: timeout) {
            if let envelope = self.socketJSON(method: "system.identify", params: [:]) {
                self.lastMainWindowContextResponse = "system.identify \(Self.debugDescription(envelope))"
                if envelope["ok"] as? Bool == true,
                   let result = envelope["result"] as? [String: Any],
                   let focused = result["focused"] as? [String: Any],
                   let windowID = focused["window_id"] as? String,
                   !windowID.isEmpty {
                    var payload: [String: Any] = ["window_id": windowID]
                    if let surfaceID = focused["surface_id"] as? String, !surfaceID.isEmpty {
                        payload["surface_id"] = surfaceID
                    }
                    return payload
                }
            } else {
                self.lastMainWindowContextResponse = "system.identify nil envelope"
            }

            if let envelope = self.socketJSON(method: "window.list", params: [:]) {
                self.lastMainWindowContextResponse += " window.list \(Self.debugDescription(envelope))"
                if envelope["ok"] as? Bool == true,
                   let result = envelope["result"] as? [String: Any],
                   let windows = result["windows"] as? [[String: Any]] {
                    let window = windows.first { item in
                        item["visible"] as? Bool == true
                    } ?? windows.first
                    if let windowID = window?["id"] as? String, !windowID.isEmpty {
                        return ["window_id": windowID]
                    }
                }
            } else {
                self.lastMainWindowContextResponse += " window.list nil envelope"
            }

            if let windowID = self.diagnosticMainWindowID() {
                self.lastMainWindowContextResponse += " diagnostics_window_id \(windowID)"
                return ["window_id": windowID]
            }
            return nil
        }
        .flatMap { payload in
            guard let windowID = payload["window_id"] as? String else { return nil }
            return (windowID, payload["surface_id"] as? String)
        }
    }

    private func diagnosticMainWindowID() -> String? {
        guard let identifiers = loadDiagnostics()["windowIdentifiers"] else { return nil }
        for rawIdentifier in identifiers.split(separator: ",") {
            let identifier = String(rawIdentifier).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "cmux.main."
            guard identifier.hasPrefix(prefix) else { continue }
            let windowID = String(identifier.dropFirst(prefix.count))
            guard UUID(uuidString: windowID) != nil else { continue }
            return windowID
        }
        return nil
    }

    private func createTextBoxFixtureWorkspace(windowID: String?, workingDirectory: String) -> [String: Any]? {
        var params: [String: Any] = [
            "title": "Textbox mention XCUITest",
            "working_directory": workingDirectory,
            "focus": true,
            "eager_load_terminal": true,
            "auto_refresh_metadata": false,
        ]
        if let windowID, !windowID.isEmpty {
            params["window_id"] = windowID
            if let result = socketResultCapturingEnvelope(method: "workspace.create", params: params) {
                return result
            }
            params.removeValue(forKey: "window_id")
        }
        return socketResultCapturingEnvelope(method: "workspace.create", params: params)
    }

    private func socketResultCapturingEnvelope(method: String, params: [String: Any]) -> [String: Any]? {
        guard let envelope = socketJSON(method: method, params: params) else {
            lastWorkspaceCreateResponse = "\(method) nil envelope"
            return nil
        }
        lastWorkspaceCreateResponse = "\(method) \(Self.debugDescription(envelope))"
        guard envelope["ok"] as? Bool == true else {
            return nil
        }
        return envelope["result"] as? [String: Any]
    }

    private func waitForTextBoxFixture(
        surfaceID: String?,
        beforeText: String,
        completionRootDirectory: String? = nil,
        timeout: TimeInterval
    ) -> [String: Any]? {
        waitForJSON(timeout: timeout) {
            var params: [String: Any] = [
                "before_text": beforeText,
                "after_text": "",
            ]
            if let surfaceID {
                params["surface_id"] = surfaceID
            }
            if let completionRootDirectory {
                params["completion_root_directory"] = completionRootDirectory
            }
            guard let envelope = self.socketJSON(method: "debug.textbox.inline_fixture", params: params) else {
                self.lastTextBoxFixtureResponse = "nil envelope"
                return nil
            }
            self.lastTextBoxFixtureResponse = Self.debugDescription(envelope)
            guard envelope["ok"] as? Bool == true,
                  let result = envelope["result"] as? [String: Any] else {
                return nil
            }
            guard result["text_view_has_window"] as? Bool == true,
                  result["text_view_text"] as? String == beforeText else {
                return nil
            }
            return result
        }
    }

    private static func debugDescription(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
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

    private func mentionPopoverRowTitles(in app: XCUIApplication) -> [String] {
        (0..<12).compactMap { index in
            let row = app.descendants(matching: .any)
                .matching(identifier: "TextBoxMentionCompletionPopover.Row.\(index)")
                .firstMatch
            guard row.exists else { return nil }
            if !row.label.isEmpty {
                return row.label
            }
            if let value = row.value as? String, !value.isEmpty {
                return value
            }
            return nil
        }
    }

    private func waitForMentionRows(
        in app: XCUIApplication,
        timeout: TimeInterval,
        predicate: @escaping ([String]) -> Bool
    ) -> [String]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rows = mentionPopoverRowTitles(in: app)
            if predicate(rows) {
                return rows
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let rows = mentionPopoverRowTitles(in: app)
        return predicate(rows) ? rows : nil
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
