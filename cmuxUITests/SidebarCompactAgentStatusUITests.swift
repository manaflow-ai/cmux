import Darwin
import Foundation
import XCTest

/// Launches cmux with `sidebar.compactAgentStatus` on, drives one workspace per
/// glyph state over the control socket, and keeps a screenshot of the sidebar
/// so reviewers and agents can see the rows (`scripts/ci/e2e-frames.py`).
final class SidebarCompactAgentStatusUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCompactStatusGlyphsRenderOnTheTitleLine() {
        runScenario(compact: true)
    }

    func testStatusRowsWithCompactStatusOff() {
        runScenario(compact: false)
    }

    /// (workspace title, socket commands for it; `{tab}` is its workspace id)
    private let scenarios: [(title: String, commands: [String])] = [
        ("needs input", ["set_agent_lifecycle claude_code needsInput --tab={tab}"]),
        ("running", ["set_agent_lifecycle claude_code running --tab={tab}"]),
        ("open PR", [
            "set_agent_lifecycle codex idle --tab={tab}",
            "report_git_branch feat/sidebar --tab={tab}",
            "report_pr 12 https://github.com/manaflow-ai/cmux/pull/12 --label=PR --state=open --tab={tab}",
        ]),
        ("merged PR", [
            "report_git_branch feat/done --tab={tab}",
            "report_pr 13 https://github.com/manaflow-ai/cmux/pull/13 --label=PR --state=merged --tab={tab}",
        ]),
        ("branch only", ["report_git_branch main --tab={tab}"]),
        ("idle agent", ["set_agent_lifecycle claude_code idle --tab={tab}"]),
        ("starting agent", ["set_agent_lifecycle claude_code unknown --tab={tab}"]),
        ("custom status", ["set_status deploy green --icon=checkmark --tab={tab}"]),
    ]

    private func runScenario(compact: Bool) {
        let app = XCUIApplication.cmuxTestApplication()
        let token = UUID().uuidString.prefix(8)
        let socketPath = "/tmp/cmux-ui-compact-status-\(token).sock"
        defer {
            app.terminate()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        app.launchArguments += ["-newWorkspacePlacement", "end"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += ["-sidebarCompactAgentStatus", compact ? "YES" : "NO"]
        app.launchArguments += ["-socketControlMode", "allowAll", "-NSAppSleepDisabled", "YES"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-compact-status-\(token)"

        launchAndEnsureRunning(app)
        XCTAssertTrue(
            pollUntil(timeout: 10.0) { self.sendSocketLine("ping", to: socketPath) == "PONG" },
            "Expected the isolated control socket to become ready"
        )

        for scenario in scenarios {
            let reply = sendSocketLine("new_workspace \(scenario.title)", to: socketPath)
            XCTAssertTrue(reply?.hasPrefix("OK ") == true, "new_workspace \(scenario.title): \(reply ?? "nil")")
        }
        var workspaceIDs: [UUID] = []
        XCTAssertTrue(
            pollUntil(timeout: 12.0) {
                workspaceIDs = self.workspaceIDs(from: self.sendSocketLine("list_workspaces", to: socketPath))
                return workspaceIDs.count == self.scenarios.count + 1
            },
            "Expected \(scenarios.count + 1) workspaces; observed \(workspaceIDs.count)"
        )
        // The launch workspace is first; the scenarios follow in creation order.
        for (scenario, workspaceID) in zip(scenarios, workspaceIDs.dropFirst()) {
            for command in scenario.commands {
                let line = command.replacingOccurrences(of: "{tab}", with: workspaceID.uuidString)
                XCTAssertEqual(sendSocketLine(line, to: socketPath), "OK", line)
            }
        }

        app.activate()
        let sidebar = app.descendants(matching: .any)["Sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5.0), "Expected the workspace sidebar")
        // Capture before asserting, so a failed assertion still leaves the picture.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let window = app.windows.firstMatch
        let shot = XCTAttachment(screenshot: window.exists ? window.screenshot() : XCUIScreen.main.screenshot())
        shot.name = compact ? "compact-status-sidebar" : "status-rows-sidebar"
        shot.lifetime = .keepAlways
        add(shot)

        if compact {
            // Glyph accessibility labels carry the tooltip text.
            for label in ["Needs input", "PR #12: open", "PR #13: merged", "main", "Idle"] {
                let glyph = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
                XCTAssertTrue(glyph.waitForExistence(timeout: 5.0), "Expected a compact status glyph labelled \(label)")
            }
        }
        // The custom (non-agent) status keeps its row in both modes.
        let customRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "green", "green")).firstMatch
        XCTAssertTrue(customRow.waitForExistence(timeout: 5.0), "Expected the custom status row to stay visible")

    }

    private func workspaceIDs(from listWorkspacesReply: String?) -> [UUID] {
        guard let listWorkspacesReply else { return [] }
        return listWorkspacesReply.split(separator: "\n").compactMap { line in
            line.split(whereSeparator: \.isWhitespace).lazy
                .compactMap { UUID(uuidString: String($0)) }
                .first
        }
    }

    private func launchAndEnsureRunning(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }
        XCTAssertTrue(
            pollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )
    }

    private func pollUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() {
                return true
            }
            if ProcessInfo.processInfo.systemUptime - start >= timeout {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }

    private func sendSocketLine(
        _ line: String,
        to path: String,
        responseTimeout: TimeInterval = 2.0
    ) -> String? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { pointer in
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(
            tv_sec: Int(responseTimeout),
            tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
        )
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_un()
        memset(&address, 0, MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            for index in pathBytes.indices {
                raw[index] = pathBytes[index]
            }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addressLength = socklen_t(pathOffset + pathBytes.count)
        address.sun_len = UInt8(min(Int(addressLength), 255))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, addressLength)
            }
        }
        guard connected == 0 else { return nil }

        let payload = Array((line + "\n").utf8)
        let wrotePayload = payload.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return Darwin.write(descriptor, baseAddress, buffer.count) == buffer.count
        }
        guard wrotePayload else { return nil }
        _ = shutdown(descriptor, SHUT_WR)

        var buffer = [UInt8](repeating: 0, count: 4096)
        var response = ""
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                guard errno == EAGAIN || errno == EWOULDBLOCK else { return nil }
                break
            }
            guard count > 0 else { break }
            response += String(decoding: buffer[0..<count], as: UTF8.self)
        }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
