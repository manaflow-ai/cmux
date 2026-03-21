import XCTest
import Foundation

final class AutomationSocketUITests: XCTestCase {
    private struct CmuxCommandResult {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }

    private struct SocketSurface {
        let id: String
    }

    private var socketPath = ""
    private var diagnosticsPath = ""
    private var ensureTerminalSurfaceFailure = ""
    private var lastPingResponse = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-automation-socket-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-diagnostics-\(UUID().uuidString).json"
        ensureTerminalSurfaceFailure = ""
        lastPingResponse = ""
        resetSocketDefaults()
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)

        let cleanup = XCUIApplication()
        cleanup.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    func testSocketToggleDisablesAndEnables() {
        let app = configuredApp(mode: "cmuxOnly")
        launchAndActivate(app)
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
        launchAndActivate(app)
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket off test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForSocket(exists: false, timeout: 3.0))
        app.terminate()
    }

    func testSurfaceListStillRespondsAfterRepeatedSendKey() {
        let app = configuredApp(mode: "allowAll")
        app.launchEnvironment["CMUX_UI_TEST_AUTOMATION_SOCKET_STRESS"] = "1"
        launchAndActivate(app)
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for repeated send-key socket test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0) else {
            XCTFail("Expected control socket to exist for repeated send-key socket test.")
            return
        }
        socketPath = resolvedPath
        guard let socketDiagnostics = waitForSocketReadyDiagnostics(timeout: 12.0) else {
            XCTFail(
                "Expected control socket diagnostics to report ready at \(socketPath). " +
                    "lastPing=\(lastPingResponse.isEmpty ? "<nil>" : lastPingResponse) " +
                    "diagnostics=\(loadDiagnostics() ?? [:])"
            )
            return
        }
        XCTAssertEqual(
            socketDiagnostics["socketPingResponse"],
            "PONG",
            "Expected app-side socket sanity ping to succeed before repeated send-key test. " +
                "diagnostics=\(socketDiagnostics)"
        )
        XCTAssertTrue(
            waitForAutomationSocketStress(timeout: 20.0),
            "Expected automation socket stress harness to finish. diagnostics=\(loadDiagnostics() ?? [:])"
        )

        let finalDiagnostics = loadDiagnostics() ?? [:]
        XCTAssertEqual(
            finalDiagnostics["automationSocketStressStatus"],
            "passed",
            "Expected repeated send_key socket stress to pass. diagnostics=\(finalDiagnostics)"
        )
        XCTAssertEqual(
            finalDiagnostics["automationSocketStressIterationsCompleted"],
            "8",
            "Expected repeated send_key socket stress to complete all iterations. diagnostics=\(finalDiagnostics)"
        )
    }

    private func configuredApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", mode]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = mode
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        return app
    }

    private func launchAndActivate(_ app: XCUIApplication) {
        app.launch()
        app.activate()
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

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                predicate()
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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

    private func waitForSocketPong(timeout: TimeInterval) -> String? {
        var lastResponse: String?
        _ = waitForCondition(timeout: timeout) {
            lastResponse = self.socketCommand("ping", responseTimeout: 1.5)
            self.lastPingResponse = lastResponse ?? ""
            return lastResponse == "PONG"
        }
        let finalResponse = lastResponse == "PONG" ? "PONG" : (socketCommand("ping", responseTimeout: 1.5) ?? lastResponse)
        lastPingResponse = finalResponse ?? ""
        return finalResponse
    }

    private func waitForSocketReadyDiagnostics(timeout: TimeInterval) -> [String: String]? {
        var lastDiagnostics: [String: String]?
        let isReady = waitForCondition(timeout: timeout) {
            guard let diagnostics = self.loadDiagnostics() else { return false }
            lastDiagnostics = diagnostics
            if let expectedPath = diagnostics["socketExpectedPath"], !expectedPath.isEmpty, expectedPath != self.socketPath {
                return false
            }
            return diagnostics["socketReady"] == "1"
        }
        return isReady ? lastDiagnostics : loadDiagnostics()
    }

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        guard waitForSocket(exists: true, timeout: timeout) else {
            return nil
        }
        return socketPath
    }

    private func waitForAutomationSocketStress(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let diagnostics = self.loadDiagnostics() else { return false }
            return diagnostics["automationSocketStressDone"] == "1"
        }
    }

    private func currentWorkspaceId() -> String? {
        guard let response = socketCommand("current_workspace", responseTimeout: 4.0)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: response) != nil else {
            return nil
        }
        return response
    }

    private func listSurfaces(workspaceId: String?) -> [SocketSurface]? {
        let command: String
        if let workspaceId, !workspaceId.isEmpty {
            command = "list_surfaces \(workspaceId)"
        } else {
            command = "list_surfaces"
        }
        guard let response = socketCommand(command, responseTimeout: 4.0) else {
            return nil
        }
        if response == "No surfaces" {
            return []
        }
        return parseSocketList(response).map { SocketSurface(id: $0.id) }
    }

    private func parseSocketList(_ response: String) -> [(id: String, isSelected: Bool)] {
        response
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine in
                var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }
                let isSelected = line.hasPrefix("*")
                if line.hasPrefix("* ") || line.hasPrefix("  ") {
                    line = String(line.dropFirst(2))
                }
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2 else { return nil }
                let id = String(parts[1])
                guard UUID(uuidString: id) != nil else { return nil }
                return (id: id, isSelected: isSelected)
            }
    }

    private func okUUID(from response: String?) -> String? {
        guard let response else { return nil }
        let parts = response.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[0] == "OK" else { return nil }
        let id = String(parts[1])
        guard UUID(uuidString: id) != nil else { return nil }
        return id
    }

    private func socketCommand(_ command: String, responseTimeout: TimeInterval = 2.0) -> String? {
        if let response = ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendLine(command) {
            return response
        }
        return socketCommandViaNetcat(command, responseTimeout: responseTimeout)
    }

    private func socketCommandViaNetcat(_ command: String, responseTimeout: TimeInterval = 2.0) -> String? {
        let netcatPath = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: netcatPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        let script =
            "printf '%s\\n' \(shellSingleQuote(command)) | " +
            "\(netcatPath) -U \(shellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
        process.arguments = ["-lc", script]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8) else { return nil }
        if let firstLine = output.split(separator: "\n", maxSplits: 1).first {
            return String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func ensureTerminalSurface(timeout: TimeInterval) -> (workspaceId: String, surfaceId: String)? {
        ensureTerminalSurfaceFailure = ""
        var traceParts: [String] = [
            "ping=\(socketCommand("ping", responseTimeout: 1.5) ?? "<nil>")",
            "current-window=\(socketCommand("current_window", responseTimeout: 4.0) ?? "<nil>")",
            "current-workspace=\(socketCommand("current_workspace", responseTimeout: 4.0) ?? "<nil>")",
            "list-workspaces.initial=\(socketCommand("list_workspaces", responseTimeout: 4.0) ?? "<nil>")",
            "list-surfaces.initial=\(socketCommand("list_surfaces", responseTimeout: 4.0) ?? "<nil>")",
        ]

        let foundExistingSurface = waitForCondition(timeout: min(timeout, 6.0)) {
            self.terminalSurface() != nil
        }
        traceParts.append("existing-surface-ready=\(foundExistingSurface ? "1" : "0")")
        if let target = terminalSurface() {
            ensureTerminalSurfaceFailure = traceParts.joined(separator: " | ")
            return target
        }

        let workspaceCreateResult = socketCommand("new_workspace", responseTimeout: 4.0)
        traceParts.append("new-workspace=\(workspaceCreateResult ?? "<nil>")")
        guard let workspaceId = okUUID(from: workspaceCreateResult) else {
            ensureTerminalSurfaceFailure = traceParts.joined(separator: " | ")
            return nil
        }

        let workspaceSelectResult = socketCommand("select_workspace \(workspaceId)", responseTimeout: 4.0)
        traceParts.append("select-workspace=\(workspaceSelectResult ?? "<nil>")")
        guard workspaceSelectResult == "OK" else {
            ensureTerminalSurfaceFailure = traceParts.joined(separator: " | ")
            return nil
        }

        let ready = waitForCondition(timeout: timeout) {
            self.terminalSurface(workspaceId: workspaceId) != nil
        }
        traceParts.append("list-workspaces.created=\(self.socketCommand("list_workspaces", responseTimeout: 4.0) ?? "<nil>")")
        traceParts.append("list-surfaces.created=\(self.socketCommand("list_surfaces \(workspaceId)", responseTimeout: 4.0) ?? "<nil>")")
        ensureTerminalSurfaceFailure = traceParts.joined(separator: " | ")
        guard ready else { return nil }
        return terminalSurface(workspaceId: workspaceId)
    }

    private func terminalSurface(workspaceId: String? = nil) -> (workspaceId: String, surfaceId: String)? {
        guard let resolvedWorkspaceId = workspaceId ?? currentWorkspaceId(),
              let surfaces = listSurfaces(workspaceId: resolvedWorkspaceId),
              let surface = surfaces.first else {
            return nil
        }
        return (workspaceId: resolvedWorkspaceId, surfaceId: surface.id)
    }

    private func resolvedWindowId(from payload: [String: Any]?) -> String? {
        guard let windows = payload?["windows"] as? [[String: Any]], !windows.isEmpty else {
            return nil
        }
        let preferred = windows.first(where: { ($0["key"] as? Bool) == true }) ??
            windows.first(where: { ($0["visible"] as? Bool) == true }) ??
            windows.first
        guard let windowId = preferred?["id"] as? String, !windowId.isEmpty else {
            return nil
        }
        return windowId
    }

    private func workspaceList(windowId: String?) -> (command: CmuxCommandResult, payload: [String: Any]?)? {
        guard let windowId, !windowId.isEmpty else { return nil }
        return runCmuxJSON(
            arguments: [
                "--window",
                windowId,
                "list-workspaces",
            ],
            responseTimeoutSeconds: 4.0
        )
    }

    private func panelList(
        windowId: String?,
        workspaceId: String?
    ) -> (command: CmuxCommandResult, payload: [String: Any]?)? {
        guard let windowId, !windowId.isEmpty else { return nil }
        var arguments = [
            "--window",
            windowId,
            "list-panels",
        ]
        if let workspaceId, !workspaceId.isEmpty {
            arguments.append(contentsOf: ["--workspace", workspaceId])
        }
        return runCmuxJSON(arguments: arguments, responseTimeoutSeconds: 4.0)
    }

    private func runCmuxJSON(
        arguments: [String],
        responseTimeoutSeconds: Double = 3.0
    ) -> (command: CmuxCommandResult, payload: [String: Any]?)? {
        let command = runCmuxCommand(
            arguments: ["--json", "--id-format", "uuids"] + arguments,
            responseTimeoutSeconds: responseTimeoutSeconds
        )
        let raw = command.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return (command: command, payload: nil)
        }
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (command: command, payload: nil)
        }
        return (command: command, payload: payload)
    }

    private func runCmuxCommand(
        arguments: [String],
        responseTimeoutSeconds: Double = 3.0
    ) -> CmuxCommandResult {
        var args = ["--socket", socketPath]
        args.append(contentsOf: arguments)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = String(responseTimeoutSeconds)

        let cliPaths = resolveCmuxCLIPaths()
        if cliPaths.isEmpty {
            return CmuxCommandResult(
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to locate bundled cmux CLI"
            )
        }

        var lastPermissionFailure: CmuxCommandResult?
        for cliPath in cliPaths {
            let result = executeCmuxCommand(
                executablePath: cliPath,
                arguments: args,
                environment: environment
            )
            if result.terminationStatus == 0 {
                return result
            }
            if isSocketPermissionFailure(result.stderr) {
                lastPermissionFailure = result
                continue
            }
            return result
        }

        let fallbackResult = executeCmuxCommand(
            executablePath: "/usr/bin/env",
            arguments: ["cmux"] + args,
            environment: environment
        )
        if fallbackResult.terminationStatus == 0 || lastPermissionFailure == nil {
            return fallbackResult
        }
        return lastPermissionFailure ?? fallbackResult
    }

    private func describeCommandResult(_ result: (command: CmuxCommandResult, payload: [String: Any]?)?) -> String {
        guard let result else { return "<nil>" }
        let stdout = result.command.stdout.isEmpty ? "<empty>" : result.command.stdout
        let stderr = result.command.stderr.isEmpty ? "<empty>" : result.command.stderr
        return "status=\(result.command.terminationStatus) stdout=\(stdout) stderr=\(stderr)"
    }

    private func resolveCmuxCLIPaths() -> [String] {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        var productDirectories: [String] = []

        for key in ["CMUX_UI_TEST_CLI_PATH", "CMUXTERM_CLI"] {
            if let value = env[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append(value)
            }
        }

        if let builtProductsDir = env["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            productDirectories.append(builtProductsDir)
        }

        if let hostPath = env["TEST_HOST"], !hostPath.isEmpty {
            let hostURL = URL(fileURLWithPath: hostPath)
            let productsDir = hostURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            productDirectories.append(productsDir)
        }

        productDirectories.append(contentsOf: inferredBuildProductsDirectories())
        for productsDir in uniquePaths(productDirectories) {
            appendCLIPathCandidates(fromProductsDirectory: productsDir, to: &candidates)
        }

        var resolvedPaths: [String] = []
        for path in uniquePaths(candidates) {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            resolvedPaths.append(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        return uniquePaths(resolvedPaths)
    }

    private func inferredBuildProductsDirectories() -> [String] {
        let bundleURLs = [
            Bundle.main.bundleURL,
            Bundle(for: Self.self).bundleURL,
        ]

        return bundleURLs.compactMap { bundleURL in
            let standardizedPath = bundleURL.standardizedFileURL.path
            let components = standardizedPath.split(separator: "/")
            guard let productsIndex = components.firstIndex(of: "Products"),
                  productsIndex + 1 < components.count else {
                return nil
            }
            let prefixComponents = components.prefix(productsIndex + 2)
            return "/" + prefixComponents.joined(separator: "/")
        }
    }

    private func appendCLIPathCandidates(fromProductsDirectory productsDir: String, to candidates: inout [String]) {
        candidates.append("\(productsDir)/cmux DEV.app/Contents/Resources/bin/cmux")
        candidates.append("\(productsDir)/cmux.app/Contents/Resources/bin/cmux")
        candidates.append("\(productsDir)/cmux")

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir) else {
            return
        }

        for entry in entries.sorted() where entry.hasSuffix(".app") {
            let cliPath = URL(fileURLWithPath: productsDir)
                .appendingPathComponent(entry)
                .appendingPathComponent("Contents/Resources/bin/cmux")
                .path
            candidates.append(cliPath)
        }
        for entry in entries.sorted() where entry == "cmux" {
            let cliPath = URL(fileURLWithPath: productsDir)
                .appendingPathComponent(entry)
                .path
            candidates.append(cliPath)
        }
    }

    private func executeCmuxCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> CmuxCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CmuxCommandResult(
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to run cmux command: \(error.localizedDescription) (cliPath=\(executablePath))"
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawStderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = rawStderr.isEmpty ? "" : "\(rawStderr) (cliPath=\(executablePath))"
        return CmuxCommandResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private func isSocketPermissionFailure(_ stderr: String?) -> Bool {
        guard let stderr, !stderr.isEmpty else { return false }
        return stderr.localizedCaseInsensitiveContains("failed to connect to socket") &&
            stderr.localizedCaseInsensitiveContains("operation not permitted")
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for path in paths {
            if seen.insert(path).inserted {
                unique.append(path)
            }
        }
        return unique
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

#if os(macOS)
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
#endif
            var socketTimeout = timeval(
                tv_sec: Int(responseTimeout.rounded(.down)),
                tv_usec: Int32(((responseTimeout - floor(responseTimeout)) * 1_000_000).rounded())
            )
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_SNDTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
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
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cstr in
                var remaining = strlen(cstr)
                var pointer = UnsafeRawPointer(cstr)
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written <= 0 { return false }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
            guard wrote else { return nil }

            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulator = ""
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 {
                    let code = errno
                    if code == EAGAIN || code == EWOULDBLOCK {
                        break
                    }
                    return nil
                }
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

    private func loadDiagnostics() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }
}
