import XCTest
import Foundation

final class TmuxRunnerProofUITests: XCTestCase {
    private var sessionName = ""
    private var shellReadyPath = ""
    private var tmuxPathPath = ""
    private var proofPath = ""
    private var tmuxCommandOutputPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let id = UUID().uuidString
        sessionName = "ui-runner-proof-\(Int(Date().timeIntervalSince1970))"
        shellReadyPath = "/tmp/cmux-ui-test-shell-ready-\(id).txt"
        tmuxPathPath = "/tmp/cmux-ui-test-tmux-path-\(id).txt"
        proofPath = "/tmp/cmux-ui-test-tmux-proof-\(id).txt"
        tmuxCommandOutputPath = "/tmp/cmux-ui-test-tmux-command-\(id).txt"
        try? FileManager.default.removeItem(atPath: shellReadyPath)
        try? FileManager.default.removeItem(atPath: tmuxPathPath)
        try? FileManager.default.removeItem(atPath: proofPath)
        try? FileManager.default.removeItem(atPath: tmuxCommandOutputPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: shellReadyPath)
        try? FileManager.default.removeItem(atPath: tmuxPathPath)
        try? FileManager.default.removeItem(atPath: proofPath)
        try? FileManager.default.removeItem(atPath: tmuxCommandOutputPath)
        super.tearDown()
    }

    func testRunnerProofEchoTmuxEnvAndScreenshot() {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "cmuxOnly"]
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "cmuxOnly"
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 15.0),
            "Expected app to launch in foreground for tmux runner proof"
        )

        if app.windows.count > 0 {
            app.windows.firstMatch.click()
        }
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        typeAndEnter(app, "printf 'SHELL_READY\\n' > \(shellReadyPath)")
        let shellReady = waitFor(timeout: 10.0) {
            FileManager.default.fileExists(atPath: self.shellReadyPath)
        }
        XCTAssertTrue(shellReady, "Expected shell readiness marker at \(shellReadyPath)")

        typeAndEnter(app, "command -v tmux > \(tmuxPathPath)")
        let tmuxPathReady = waitFor(timeout: 10.0) {
            FileManager.default.fileExists(atPath: self.tmuxPathPath)
        }
        XCTAssertTrue(tmuxPathReady, "Expected tmux path marker at \(tmuxPathPath)")
        let tmuxPath = (try? String(contentsOfFile: tmuxPathPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(tmuxPath.isEmpty, "Expected tmux in shell PATH")

        typeAndEnter(app, "tmux kill-session -t \(sessionName) >/dev/null 2>&1 || true")

        let token = "TMUX_PROOF_\(Int(Date().timeIntervalSince1970))"
        typeAndEnter(app, "tmux new-session -d -s \(sessionName) > \(tmuxCommandOutputPath) 2>&1")

        let commandOutputReady = waitFor(timeout: 10.0) {
            FileManager.default.fileExists(atPath: self.tmuxCommandOutputPath)
        }
        XCTAssertTrue(
            commandOutputReady,
            "Expected tmux command output marker at \(tmuxCommandOutputPath)"
        )
        typeAndEnter(
            app,
            "tmux send-keys -t \(sessionName) 'echo \(token) TMUX=$TMUX TMUX_PANE=$TMUX_PANE > \(proofPath)' C-m"
        )

        let proofReady = waitFor(timeout: 10.0) {
            FileManager.default.fileExists(atPath: self.proofPath)
        }
        let tmuxCommandOutput = (try? String(contentsOfFile: tmuxCommandOutputPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertTrue(
            proofReady,
            "Expected tmux proof file at \(proofPath). tmux new-session output=\(tmuxCommandOutput)"
        )

        let proofLine = (try? String(contentsOfFile: proofPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(proofLine.isEmpty, "Expected non-empty tmux proof output")

        guard let parsed = parseProofLine(proofLine, token: token) else {
            XCTFail("Unable to parse proof line: \(proofLine)")
            return
        }

        XCTAssertFalse(parsed.tmuxValue.isEmpty, "Expected non-empty $TMUX: \(proofLine)")
        XCTAssertTrue(parsed.tmuxPaneValue.hasPrefix("%"), "Expected $TMUX_PANE to start with %: \(proofLine)")

        typeAndEnter(app, "cat \(proofPath)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let screenshot = XCUIScreen.main.screenshot()
        let screenshotAttachment = XCTAttachment(screenshot: screenshot)
        screenshotAttachment.name = "tmux-runner-proof-screenshot"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        let payload: [String: Any] = [
            "session": sessionName,
            "proofLine": proofLine,
            "tmux": parsed.tmuxValue,
            "tmuxPane": parsed.tmuxPaneValue,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8)
        {
            let jsonAttachment = XCTAttachment(string: json)
            jsonAttachment.name = "tmux-runner-proof-json"
            jsonAttachment.lifetime = .keepAlways
            add(jsonAttachment)
        }

        app.terminate()
    }

    private func parseProofLine(_ line: String, token: String) -> (tmuxValue: String, tmuxPaneValue: String)? {
        let cleaned = line
            .replacingOccurrences(
                of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "\(escaped) TMUX=(\\S+) TMUX_PANE=(\\S+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let ns = cleaned as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: cleaned, range: range), match.numberOfRanges >= 3 else {
            return nil
        }
        let tmuxValue = ns.substring(with: match.range(at: 1))
        let tmuxPaneValue = ns.substring(with: match.range(at: 2))
        return (tmuxValue, tmuxPaneValue)
    }

    private func typeAndEnter(_ app: XCUIApplication, _ command: String) {
        app.typeText(command)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
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

    private struct ProcessResult {
        let exitCode: Int32
        let output: String
    }

    private func runProcess(_ executable: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, output: "failed_to_run: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let merged = [out, err]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessResult(exitCode: process.terminationStatus, output: merged)
    }
}
