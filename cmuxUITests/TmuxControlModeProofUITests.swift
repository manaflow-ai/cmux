import XCTest
import Foundation

final class TmuxControlModeProofUITests: XCTestCase {
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"

    private var socketPath = ""
    private var proofPath = ""
    private var launchTag = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-socket-\(UUID().uuidString).sock"
        proofPath = "/tmp/cmux-ui-test-tmux-proof-\(UUID().uuidString).json"
        launchTag = "ui-tests-tmux-proof-\(UUID().uuidString.prefix(8))"
        resetSocketDefaults()
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: proofPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: proofPath)
        super.tearDown()
    }

    func testTmuxControlModeProofCapturesScreenshotAndEnv() throws {
        let app = configuredApp(mode: "allowAll")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 15.0),
            "Expected app to launch in foreground for tmux proof test"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 8.0) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath

        XCTAssertTrue(waitForSocketPong(timeout: 6.0), "Socket ping did not succeed at \(socketPath)")

        guard let workspaceBefore = socketCommand("current_workspace"), workspaceBefore.hasPrefix("OK ") else {
            XCTFail("Failed to read current workspace before tmux start. response=\(socketCommand("current_workspace") ?? "nil")")
            return
        }

        let session = "ui-tmux-proof-\(Int(Date().timeIntervalSince1970))"
        let startResponse = socketCommand("send cmux tmux start --session \(session)\\n")
        XCTAssertEqual(startResponse, "OK", "Failed to send tmux start command. response=\(startResponse ?? "nil")")

        var workspaceAfter = workspaceBefore
        let switched = waitFor(timeout: 30.0) {
            guard let current = self.socketCommand("current_workspace"), current.hasPrefix("OK ") else {
                return false
            }
            workspaceAfter = current
            return current != workspaceBefore
        }
        XCTAssertTrue(switched, "Expected tmux start to switch to a new workspace. before=\(workspaceBefore) after=\(workspaceAfter)")

        let sendProofResponse = socketCommand("send echo TMUX_PROOF TMUX=$TMUX TMUX_PANE=$TMUX_PANE\\n")
        XCTAssertEqual(sendProofResponse, "OK", "Failed to send tmux env echo command. response=\(sendProofResponse ?? "nil")")

        let pattern = try NSRegularExpression(
            pattern: #"TMUX_PROOF TMUX=(\S+) TMUX_PANE=(\S+)"#,
            options: []
        )
        var proofLine = ""
        var tmuxValue = ""
        var tmuxPaneValue = ""
        var latestScreen = ""

        let foundProof = waitFor(timeout: 30.0) {
            guard let text = self.socketCommand("read_screen --scrollback --lines 400") else {
                return false
            }
            latestScreen = text

            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = pattern.firstMatch(in: text, options: [], range: range), match.numberOfRanges >= 3 else {
                return false
            }

            proofLine = ns.substring(with: match.range(at: 0))
            tmuxValue = ns.substring(with: match.range(at: 1))
            tmuxPaneValue = ns.substring(with: match.range(at: 2))
            return true
        }
        XCTAssertTrue(
            foundProof,
            "Timed out waiting for TMUX proof line in terminal output. latestScreenTail=\(tail(latestScreen, maxLines: 60))"
        )
        XCTAssertFalse(tmuxValue.isEmpty, "Expected non-empty $TMUX in proof line: \(proofLine)")
        XCTAssertTrue(tmuxPaneValue.hasPrefix("%"), "Expected $TMUX_PANE to look like %<pane-id>. proof=\(proofLine)")

        let clientList = runProcess("/usr/bin/tmux", arguments: ["list-clients", "-F", "#{client_control_mode} #{session_name} #{client_tty}"])
        XCTAssertTrue(
            clientList.contains("1 \(session)"),
            "Expected attached tmux control-mode client for session \(session). list-clients=\(clientList)"
        )

        guard let screenshotResponse = socketCommand("screenshot tmux-proof"),
              screenshotResponse.hasPrefix("OK ") else {
            XCTFail("Failed to capture screenshot. response=\(socketCommand("screenshot tmux-proof") ?? "nil")")
            return
        }

        let screenshotParts = screenshotResponse.split(separator: " ", maxSplits: 2).map(String.init)
        guard screenshotParts.count >= 3 else {
            XCTFail("Unexpected screenshot response format: \(screenshotResponse)")
            return
        }
        let screenshotPath = screenshotParts[2]
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshotPath), "Screenshot file missing at \(screenshotPath)")

        let screenshotAttachment = XCTAttachment(contentsOfFile: URL(fileURLWithPath: screenshotPath))
        screenshotAttachment.name = "tmux-proof-runner-window"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        let proof: [String: Any] = [
            "session": session,
            "workspaceBefore": workspaceBefore,
            "workspaceAfter": workspaceAfter,
            "proofLine": proofLine,
            "tmux": tmuxValue,
            "tmuxPane": tmuxPaneValue,
            "screenshotPath": screenshotPath,
            "socketPath": socketPath,
            "tmuxClients": clientList
        ]
        if let data = try? JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: proofPath))
            let proofAttachment = XCTAttachment(string: String(data: data, encoding: .utf8) ?? "")
            proofAttachment.name = "tmux-proof-json"
            proofAttachment.lifetime = .keepAlways
            add(proofAttachment)
        }

        app.terminate()
    }

    private func configuredApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", mode]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_MODE"] = mode
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        return app
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in expectedSocketCandidates() {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                if socketRespondsToPing(at: candidate) {
                    return candidate
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        for candidate in expectedSocketCandidates() {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            if socketRespondsToPing(at: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func expectedSocketCandidates() -> [String] {
        var candidates = [socketPath]
        let taggedDebugSocket = "/tmp/cmux-debug-\(launchTag).sock"
        if taggedDebugSocket != socketPath {
            candidates.append(taggedDebugSocket)
        }
        return candidates
    }

    private func socketRespondsToPing(at path: String) -> Bool {
        let originalPath = socketPath
        socketPath = path
        defer { socketPath = originalPath }
        return socketCommand("ping") == "PONG"
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if socketCommand("ping") == "PONG" {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return socketCommand("ping") == "PONG"
    }

    private func waitFor(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func socketCommand(_ cmd: String) -> String? {
        if let response = ControlSocketClient(path: socketPath).sendLine(cmd) {
            return response
        }
        return socketCommandViaNetcat(cmd)
    }

    private func socketCommandViaNetcat(_ cmd: String) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-lc",
            "printf '%s\\n' \(shellSingleQuote(cmd)) | \(nc) -U \(shellSingleQuote(socketPath)) -w 2 2>/dev/null"
        ]

        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
        if let first = outStr.split(separator: "\n", maxSplits: 1).first {
            return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func runProcess(_ executable: String, arguments: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return "failed_to_run: \(error.localizedDescription)"
        }
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return "\(out)\n\(err)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tail(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private func resetSocketDefaults() {
        let deleteMode = Process()
        deleteMode.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        deleteMode.arguments = ["delete", defaultsDomain, modeKey]
        do {
            try deleteMode.run()
            deleteMode.waitUntilExit()
        } catch {
        }

        let deleteLegacy = Process()
        deleteLegacy.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        deleteLegacy.arguments = ["delete", defaultsDomain, legacyKey]
        do {
            try deleteLegacy.run()
            deleteLegacy.waitUntilExit()
        } catch {
        }
    }

    private final class ControlSocketClient {
        private let path: String

        init(path: String) {
            self.path = path
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
            }
#endif

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let bytes = Array(path.utf8CString)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for i in 0..<bytes.count {
                    raw[i] = bytes[i]
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
                var p = UnsafeRawPointer(cstr)
                while remaining > 0 {
                    let n = write(fd, p, remaining)
                    if n <= 0 { return false }
                    remaining -= n
                    p = p.advanced(by: n)
                }
                return true
            }
            guard wrote else { return nil }

            var buf = [UInt8](repeating: 0, count: 8192)
            var accum = ""
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    accum.append(chunk)
                    if let idx = accum.firstIndex(of: "\n") {
                        return String(accum[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            return accum.isEmpty ? nil : accum.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
