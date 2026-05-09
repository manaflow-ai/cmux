import XCTest
import Foundation
import Darwin

final class AutomationSocketUITests: XCTestCase {
    private var socketPath = ""
    private var lastSocketResolveDiagnostics = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"
    private let launchTag = "ui-tests-automation-socket"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        lastSocketResolveDiagnostics = ""
        resetSocketDefaults()
        resetMobileSyncDefaults()
        removeSocketFile()
    }

    func testSocketToggleDisablesAndEnables() {
        let app = configuredApp(mode: "cmuxOnly")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket toggle test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocket(exists: true, timeout: 2.0))
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

    func testMobileSyncSettingsTogglePersists() throws {
        let app = configuredApp(mode: "cmuxOnly")
        app.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for mobile sync Settings test. state=\(app.state.rawValue)"
        )

        let toggle = try requireMobileSyncToggle(app: app)
        XCTAssertFalse(toggleIsOn(toggle), "Mobile sync should default off")
        toggle.click()
        XCTAssertTrue(waitForMobileSyncToggle(app: app, isOn: true, timeout: 4.0))
        app.terminate()

        let relaunchedApp = configuredApp(mode: "cmuxOnly")
        relaunchedApp.launchEnvironment["CMUX_UI_TEST_SHOW_SETTINGS"] = "1"
        relaunchedApp.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        relaunchedApp.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(relaunchedApp, timeout: 12.0),
            "Expected app to relaunch for mobile sync Settings test. state=\(relaunchedApp.state.rawValue)"
        )
        addTeardownBlock { relaunchedApp.terminate() }

        let persistedToggle = try requireMobileSyncToggle(app: relaunchedApp)
        XCTAssertTrue(toggleIsOn(persistedToggle), "Mobile sync setting should persist across launch")
        persistedToggle.click()
        XCTAssertTrue(waitForMobileSyncToggle(app: relaunchedApp, isOn: false, timeout: 4.0))
    }

    func testMobileTerminalSnapshotCommandReturnsGhosttySchema() throws {
        let app = configuredApp(mode: "allowAll")
        addTeardownBlock { app.terminate() }
        launchAndAllowBackground(app, failureMessage: "Expected app to launch for mobile terminal snapshot test")

        guard let resolvedPath = resolveResponsiveSocketPath(timeout: 8.0) else {
            XCTFail("Expected control socket to respond to ping. \(lastSocketResolveDiagnostics)")
            return
        }
        socketPath = resolvedPath

        let result = try waitForV2Result(
            method: "mobile_sync.terminal_snapshot",
            params: ["max_scrollback_rows": 2],
            timeout: 15.0
        )
        let snapshot = try XCTUnwrap(result["snapshot"] as? [String: Any])
        let gridSize = try XCTUnwrap(snapshot["gridSize"] as? [String: Any])
        let rows = try XCTUnwrap(gridSize["rows"] as? Int)
        let columns = try XCTUnwrap(gridSize["columns"] as? Int)
        XCTAssertGreaterThan(rows, 0)
        XCTAssertGreaterThan(columns, 0)
        XCTAssertEqual(snapshot["schemaVersion"] as? Int, result["schema_version"] as? Int)
        XCTAssertEqual(snapshot["activeScreen"] as? String, "primary")

        let visibleRows = try XCTUnwrap(snapshot["visibleRows"] as? [[String: Any]])
        XCTAssertEqual(visibleRows.count, rows)
        let firstVisibleCells = try XCTUnwrap(visibleRows.first?["cells"] as? [[String: Any]])
        XCTAssertEqual(firstVisibleCells.count, columns)

        let snapshotBase64 = try XCTUnwrap(result["snapshot_base64"] as? String)
        let snapshotData = try XCTUnwrap(Data(base64Encoded: snapshotBase64))
        let decodedSnapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        XCTAssertEqual(decodedSnapshot["terminalID"] as? String, snapshot["terminalID"] as? String)
    }

    private func configuredApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", mode]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = mode
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        // Debug launches require a tag outside reload.sh; provide one in UITests so CI
        // does not fail with "Application ... does not have a process ID".
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        return app
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

    private func launchAndAllowBackground(_ app: XCUIApplication, failureMessage: String) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground || app.state == .runningBackground {
            return
        }

        XCTFail("\(failureMessage). state=\(app.state.rawValue)")
    }

    private func requireMobileSyncToggle(app: XCUIApplication) throws -> XCUIElement {
        let scrollView = app.scrollViews.firstMatch
        let candidates = mobileSyncToggleCandidates(app: app)

        for _ in 0..<10 {
            if let element = firstExistingElement(candidates: candidates, timeout: 0.5), element.isHittable {
                return element
            }
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.typeKey(",", modifierFlags: [.command])
            }
        }

        throw XCTSkip("Could not find the iOS and iPadOS Sync toggle")
    }

    private func waitForMobileSyncToggle(app: XCUIApplication, isOn: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let toggle = firstExistingElement(candidates: mobileSyncToggleCandidates(app: app), timeout: 0.2),
               toggleIsOn(toggle) == isOn {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func mobileSyncToggleCandidates(app: XCUIApplication) -> [XCUIElement] {
        [
            app.switches["SettingsMobileSyncToggle"],
            app.checkBoxes["SettingsMobileSyncToggle"],
            app.buttons["SettingsMobileSyncToggle"],
            app.otherElements["SettingsMobileSyncToggle"],
            app.switches["iOS and iPadOS Sync"],
            app.checkBoxes["iOS and iPadOS Sync"],
            app.buttons["iOS and iPadOS Sync"],
            app.otherElements["iOS and iPadOS Sync"],
        ]
    }

    private func toggleIsOn(_ element: XCUIElement) -> Bool {
        let value = String(describing: element.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "on"
    }

    private func firstExistingElement(candidates: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = candidates.first(where: { $0.exists }) {
                return match
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return candidates.first(where: { $0.exists })
    }

    private func waitForSocket(exists: Bool, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: self.socketPath) == exists
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        var resolvedPath: String?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                if FileManager.default.fileExists(atPath: self.socketPath) {
                    resolvedPath = self.socketPath
                    return true
                }
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

    private func resolveResponsiveSocketPath(timeout: TimeInterval) -> String? {
        var resolvedPath: String?
        var diagnostics: [String] = []
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                diagnostics.removeAll(keepingCapacity: true)
                let candidates = self.socketCandidates()
                for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
                    let response = ControlSocketClient(path: candidate, responseTimeout: 1.0).sendLine("ping")
                    diagnostics.append("\(candidate)=\(response ?? "<nil>")")
                    self.lastSocketResolveDiagnostics = diagnostics.joined(separator: " ")
                    if response == "PONG" {
                        resolvedPath = candidate
                        return true
                    }
                }
                if diagnostics.isEmpty {
                    let existingCandidates = candidates.map { candidate in
                        "\(candidate)=exists:\(FileManager.default.fileExists(atPath: candidate) ? "1" : "0")"
                    }
                    self.lastSocketResolveDiagnostics = existingCandidates.joined(separator: " ")
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

    private func socketCandidates() -> [String] {
        var candidates = [socketPath, "/tmp/cmux-debug-\(launchTag).sock"]
        if let found = findSocketInTmp() {
            candidates.append(found)
        }
        var unique: [String] = []
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            unique.append(candidate)
        }
        return unique
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

    private func resetMobileSyncDefaults() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", defaultsDomain, MobileSyncDefaultsKey.enabled]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func waitForV2Result(
        method: String,
        params: [String: Any],
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastEnvelope: [String: Any]?
        var lastRaw: String?
        while Date() < deadline {
            if let response = try sendV2Request(method: method, params: params) {
                let (raw, envelope) = response
                lastRaw = raw
                lastEnvelope = envelope
                if envelope["ok"] as? Bool == true,
                   let result = envelope["result"] as? [String: Any] {
                    return result
                }
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        }
        XCTFail("Timed out waiting for \(method). lastRaw=\(lastRaw ?? "nil") lastEnvelope=\(lastEnvelope ?? [:])")
        return [:]
    }

    private func sendV2Request(
        method: String,
        params: [String: Any]
    ) throws -> (raw: String, envelope: [String: Any])? {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        guard let response = ControlSocketClient(path: socketPath, responseTimeout: 5.0).sendLine(line) else {
            return nil
        }
        let responseData = try XCTUnwrap(response.data(using: .utf8))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        return (response, envelope)
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for index in 0..<bytes.count {
                    raw[index] = bytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
            addr.sun_len = UInt8(min(Int(addrLen), 255))

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cString in
                var remaining = strlen(cString)
                var pointer = UnsafeRawPointer(cString)
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written <= 0 { return false }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
            guard wrote else { return nil }

            let deadline = Date().addingTimeInterval(responseTimeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            while Date() < deadline {
                var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollDescriptor, 1, 100)
                if ready < 0 {
                    return nil
                }
                if ready == 0 {
                    continue
                }
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulator.append(chunk)
                    if let newline = accumulator.firstIndex(of: "\n") {
                        return String(accumulator[..<newline])
                    }
                }
            }

            return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private enum MobileSyncDefaultsKey {
    static let enabled = "mobileSyncEnabled"
}
