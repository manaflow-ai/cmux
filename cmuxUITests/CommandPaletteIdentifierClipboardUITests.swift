import AppKit
import Darwin
import XCTest

final class CommandPaletteIdentifierClipboardUITests: XCTestCase {
    private let debugDefaultsDomain = "com.cmuxterm.app.debug"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        resetMenuBarOnlyDefault()
    }

    override func tearDown() {
        resetMenuBarOnlyDefault()
        super.tearDown()
    }

    func testCmdShiftPCopyIdentifierCommandsWriteExpectedClipboardPayloads() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-menuBarOnly", "false"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(
            pollUntil(timeout: 8.0) { app.windows.count >= 1 },
            "Expected the main window to be visible"
        )

        runCommandPaletteCopyCommand(
            app: app,
            query: "copy workspace id",
            commandId: "palette.copyWorkspaceID",
            expectedClipboardKeys: ["workspace_id"]
        )
        runCommandPaletteCopyCommand(
            app: app,
            query: "copy workspace ref",
            commandId: "palette.copyWorkspaceIDAndRef",
            expectedClipboardKeys: ["workspace_ref", "workspace_id"]
        )
        runCommandPaletteCopyCommand(
            app: app,
            query: "copy pane id",
            commandId: "palette.copyPaneID",
            expectedClipboardKeys: ["pane_id"]
        )
        runCommandPaletteCopyCommand(
            app: app,
            query: "copy surface id",
            commandId: "palette.copySurfaceID",
            expectedClipboardKeys: ["surface_id"]
        )
        runCommandPaletteCopyCommand(
            app: app,
            query: "workspace pane surface",
            commandId: "palette.copyIdentifiers",
            expectedClipboardKeys: [
                "workspace_ref",
                "workspace_id",
                "pane_ref",
                "pane_id",
                "surface_ref",
                "surface_id",
            ]
        )
    }

    func testCmdShiftPOpenCmuxJSONOpensUserConfigFile() throws {
        let app = XCUIApplication.cmuxTestApplication()
        let capturePath = "/tmp/cmux-ui-test-open-cmux-json-\(UUID().uuidString).txt"
        try? FileManager.default.removeItem(atPath: capturePath)
        addTeardownBlock {
            app.terminate()
            try? FileManager.default.removeItem(atPath: capturePath)
        }

        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-menuBarOnly", "false"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_CAPTURE_OPEN_PATH"] = capturePath
        launchAndActivate(app)

        XCTAssertTrue(
            pollUntil(timeout: 8.0) { app.windows.count >= 1 },
            "Expected the main window to be visible"
        )

        openCommandPaletteCommands(app: app)
        let searchField = app.textFields["CommandPaletteSearchField"]
        searchField.typeText("open cmux json")

        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@",
            "CommandPaletteResultRow.",
            "palette.openCmuxSettingsFile"
        )
        let row = app.descendants(matching: .any)
            .matching(predicate)
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5.0), "Expected row for Open cmux.json")
        try? FileManager.default.removeItem(atPath: capturePath)
        row.click()

        let openedPath = try XCTUnwrap(
            capturedOpenPath(at: capturePath, timeout: 3.0),
            "Expected the palette action to attempt opening a file"
        )
        let expectedPath = (loginHomeDirectoryPath() as NSString)
            .appendingPathComponent(".config/cmux/cmux.json")
        XCTAssertEqual(openedPath, expectedPath)
    }

    func testConnectIPhoneCommandRemainsAvailableWhenMobileButtonFlagIsOff() throws {
        let usageHistoryKey = "commandPalette.commandUsage.v1"
        let usageDefaults = try XCTUnwrap(UserDefaults(suiteName: debugDefaultsDomain))
        let previousUsageHistory = usageDefaults.object(forKey: usageHistoryKey)
        let seededUsageHistory = try JSONSerialization.data(withJSONObject: [
            "palette.mobileConnect": [
                "useCount": 100,
                "lastUsedAt": Date().timeIntervalSince1970,
            ],
        ])
        usageDefaults.set(seededUsageHistory, forKey: usageHistoryKey)
        usageDefaults.synchronize()
        addTeardownBlock {
            if let previousUsageHistory {
                usageDefaults.set(previousUsageHistory, forKey: usageHistoryKey)
            } else {
                usageDefaults.removeObject(forKey: usageHistoryKey)
            }
            usageDefaults.synchronize()
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let socketPath = temporaryDirectory
            .appendingPathComponent("cmux-mcp-\(token).sock")
            .path
        let logPath = temporaryDirectory
            .appendingPathComponent("cmux-mcp-\(token).log")
            .path
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: logPath)

        let process = try launchSocketDrivenCommandPaletteApp(
            socketPath: socketPath,
            logPath: logPath
        )
        addTeardownBlock {
            self.terminateAppProcess(process)
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: logPath)
        }
        let socket = ControlSocketClient(path: socketPath, responseTimeout: 2.0)

        let socketReady = pollUntil(timeout: 15.0) {
            socket.sendLine("ping") == "PONG"
        }
        XCTAssertTrue(
            socketReady,
            "Expected control socket at \(socketPath). app=\(appProcessDiagnostics(process)) log=\(tailOfFile(at: logPath))"
        )
        guard socketReady else { return }

        var windowId: String?
        XCTAssertTrue(
            pollUntil(timeout: 8.0) {
                guard let response = socket.sendLine("current_window"),
                      UUID(uuidString: response) != nil else { return false }
                windowId = response
                return true
            },
            "Expected the socket to resolve a main window. log=\(tailOfFile(at: logPath))"
        )
        let resolvedWindowId = try XCTUnwrap(windowId)

        let toggleResponse = try XCTUnwrap(
            socket.sendJSON([
                "id": UUID().uuidString,
                "method": "debug.command_palette.toggle",
                "params": ["window_id": resolvedWindowId],
            ])
        )
        XCTAssertEqual(toggleResponse["ok"] as? Bool, true, "toggle failed: \(toggleResponse)")

        XCTAssertTrue(
            pollUntil(timeout: 5.0) {
                guard let result = self.commandPaletteSnapshot(
                    socket: socket,
                    windowId: resolvedWindowId
                ) else { return false }
                return result["visible"] as? Bool == true
            },
            "Expected the command palette to become visible"
        )

        var matchingSnapshot: [String: Any]?
        XCTAssertTrue(
            pollUntil(timeout: 5.0) {
                guard let result = self.commandPaletteSnapshot(
                    socket: socket,
                    windowId: resolvedWindowId
                ) else { return false }
                matchingSnapshot = result
                guard result["query"] as? String == "",
                let rows = result["results"] as? [[String: Any]],
                rows.first?["command_id"] as? String == "palette.mobileConnect" else {
                    return false
                }
                return true
            },
            "Expected Connect iPhone/iPad in the unfiltered palette while its sidebar flag is off. snapshot=\(matchingSnapshot ?? [:])"
        )
    }

    private func loginHomeDirectoryPath() -> String {
        if let passwd = getpwuid(getuid()), let home = passwd.pointee.pw_dir {
            return String(cString: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func launchAndActivate(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }

        if app.state == .runningForeground { return }

        var reachedForeground = false
        let activateOptions = XCTExpectedFailure.Options()
        activateOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: activateOptions) {
            reachedForeground = pollUntil(timeout: 4.0) {
                if app.state != .runningForeground {
                    app.activate()
                }
                return app.state == .runningForeground
            }
            XCTAssertTrue(reachedForeground, "App did not reach runningForeground before UI interactions")
        }
        if reachedForeground || app.state == .runningBackground {
            return
        }
        XCTFail("App failed to start. state=\(app.state.rawValue)")
    }

    private func resetMenuBarOnlyDefault() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", debugDefaultsDomain, "menuBarOnly", "-bool", "false"]
        do {
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(
                process.terminationStatus,
                0,
                "Failed to reset menuBarOnly default: status \(process.terminationStatus)"
            )
        } catch {
            XCTFail("Failed to reset menuBarOnly default: \(error.localizedDescription)")
        }
    }

    private func launchSocketDrivenCommandPaletteApp(
        socketPath: String,
        logPath: String
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolveAppBinaryPath())
        process.arguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-menuBarOnly", "<false/>",
            "-socketControlMode", "allowAll",
            "-cmux.flags.override.mobile-connect-button-enabled-release", "<false/>",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_UI_TEST_MODE"] = "1"
        environment["CMUX_SOCKET_ENABLE"] = "1"
        environment["CMUX_SOCKET_MODE"] = "allowAll"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        environment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        environment.removeValue(forKey: "CMUX_TAG")
        process.environment = environment

        _ = FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        return process
    }

    private func resolveAppBinaryPath() throws -> String {
        let testBundle = Bundle(for: Self.self)
        let productsDirectory = testBundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = productsDirectory.lastPathComponent.lowercased()
        let productNames = configuration.contains("release")
            ? ["cmux", "cmux DEV"]
            : ["cmux DEV", "cmux"]
        let binaryPaths = productNames.map { productName in
            productsDirectory
                .appendingPathComponent("\(productName).app")
                .appendingPathComponent("Contents/MacOS/\(productName)")
                .path
        }
        if let binaryPath = binaryPaths.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return binaryPath
        }
        throw NSError(
            domain: "CommandPaletteIdentifierClipboardUITests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "App binary not found at \(binaryPaths.joined(separator: " or ")). testBundle=\(testBundle.bundleURL.path)"
            ]
        )
    }

    private func terminateAppProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        _ = pollUntil(timeout: 5.0, pollInterval: 0.1) { !process.isRunning }
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = pollUntil(timeout: 2.0, pollInterval: 0.1) { !process.isRunning }
    }

    private func appProcessDiagnostics(_ process: Process) -> String {
        let status = process.isRunning ? "running" : String(process.terminationStatus)
        return "pid=\(process.processIdentifier) running=\(process.isRunning) status=\(status)"
    }

    private func tailOfFile(at path: String, maximumLength: Int = 2_000) -> String {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "<missing>"
        }
        return String(contents.suffix(maximumLength))
    }

    private func commandPaletteSnapshot(
        socket: ControlSocketClient,
        windowId: String
    ) -> [String: Any]? {
        guard let envelope = socket.sendJSON([
            "id": UUID().uuidString,
            "method": "debug.command_palette.results",
            "params": [
                "window_id": windowId,
                "limit": 20,
            ],
        ]),
        envelope["ok"] as? Bool == true else {
            return nil
        }
        return envelope["result"] as? [String: Any]
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
            let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fileDescriptor >= 0 else { return nil }
            defer { close(fileDescriptor) }

            var timeout = timeval(
                tv_sec: Int(responseTimeout),
                tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
            )
            withUnsafePointer(to: &timeout) { pointer in
                _ = setsockopt(
                    fileDescriptor,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    pointer,
                    socklen_t(MemoryLayout<timeval>.size)
                )
                _ = setsockopt(
                    fileDescriptor,
                    SOL_SOCKET,
                    SO_SNDTIMEO,
                    pointer,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }

            var address = sockaddr_un()
            memset(&address, 0, MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = Array(path.utf8CString)
            let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= maximumPathLength else { return nil }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
                for index in 0..<pathBytes.count {
                    raw[index] = pathBytes[index]
                }
            }

            guard let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) else {
                return nil
            }
            let addressLength = socklen_t(pathOffset + pathBytes.count)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(fileDescriptor, sockaddrPointer, addressLength)
                }
            }
            guard connected == 0 else { return nil }

            let payload = Array((line + "\n").utf8)
            let wrotePayload = payload.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return true }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(
                        fileDescriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        return false
                    }
                    if written == 0 {
                        return false
                    }
                    offset += written
                }
                return true
            }
            guard wrotePayload else { return nil }

            var buffer = [UInt8](repeating: 0, count: 4_096)
            var accumulator: [UInt8] = []
            let deadline = Date().addingTimeInterval(responseTimeout)
            while Date() < deadline {
                let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                    break
                }
                if count == 0 {
                    break
                }
                accumulator.append(contentsOf: buffer[0..<count])
                if let newline = accumulator.firstIndex(of: 0x0A) {
                    return String(decoding: accumulator[..<newline], as: UTF8.self)
                }
            }
            let trimmed = String(decoding: accumulator, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func runCommandPaletteCopyCommand(
        app: XCUIApplication,
        query: String,
        commandId: String,
        expectedClipboardKeys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        NSPasteboard.general.clearContents()
        openCommandPaletteCommands(app: app)
        let searchField = app.textFields["CommandPaletteSearchField"]
        searchField.typeText(query)

        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@",
            "CommandPaletteResultRow.",
            commandId
        )
        let row = app.descendants(matching: .any)
            .matching(predicate)
            .firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 5.0),
            "Expected row for command \(commandId)",
            file: file,
            line: line
        )
        row.click()
        XCTAssertTrue(
            pollUntil(timeout: 2.0) { !searchField.exists },
            "Expected command palette to dismiss after \(commandId)",
            file: file,
            line: line
        )

        let observed = waitForIdentifierClipboard(keys: expectedClipboardKeys, timeout: 2.0)
        XCTAssertTrue(
            identifierClipboardPayloadMatches(observed, keys: expectedClipboardKeys),
            "Expected clipboard keys \(expectedClipboardKeys), got \(observed ?? "<nil>")",
            file: file,
            line: line
        )
    }

    private func openCommandPaletteCommands(app: XCUIApplication) {
        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
    }

    private func capturedOpenPath(at path: String, timeout: TimeInterval) -> String? {
        var captured: String?
        let matched = pollUntil(timeout: timeout) {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            captured = contents
                .split(separator: "\n")
                .map(String.init)
                .first
            return captured != nil
        }
        return matched ? captured : nil
    }

    private func waitForIdentifierClipboard(keys: [String], timeout: TimeInterval) -> String? {
        var latest: String?
        _ = pollUntil(timeout: timeout) {
            latest = NSPasteboard.general.string(forType: .string)
            return identifierClipboardPayloadMatches(latest, keys: keys)
        }
        return latest
    }

    private func identifierClipboardPayloadMatches(_ payload: String?, keys: [String]) -> Bool {
        guard let payload else { return false }
        let lines = payload.components(separatedBy: "\n")
        guard lines.count == keys.count else { return false }
        return zip(lines, keys).allSatisfy { line, key in
            guard line.hasPrefix("\(key)=") else { return false }
            let value = String(line.dropFirst(key.count + 1))
            if key.hasSuffix("_id") {
                return UUID(uuidString: value) != nil
            }
            if key.hasSuffix("_ref") {
                let expectedPrefix: String
                switch key {
                case "workspace_ref":
                    expectedPrefix = "workspace:"
                case "pane_ref":
                    expectedPrefix = "pane:"
                case "surface_ref":
                    expectedPrefix = "surface:"
                default:
                    return false
                }
                guard value.hasPrefix(expectedPrefix) else { return false }
                return Int(value.dropFirst(expectedPrefix.count)) != nil
            }
            return false
        }
    }

    private func pollUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() {
                return true
            }
            if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
    }
}
