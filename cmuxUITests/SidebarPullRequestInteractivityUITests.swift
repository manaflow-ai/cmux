import XCTest

final class SidebarPullRequestInteractivityUITests: XCTestCase {
    private var socketPath = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let launchTag = "ui-tests-sidebar-pr-interactivity"
    private let pullRequestNumber = 123
    private var pullRequestURL: String {
        "https://github.com/manaflow-ai/cmux/pull/\(pullRequestNumber)"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-ui-test-sidebar-pr-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
        deleteSidebarClickabilityDefault()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    func testSidebarPullRequestClickFallsThroughByDefault() throws {
        try assertSidebarPullRequestClickFallsThrough(clickabilityOverride: nil, expectsPlainText: true)
    }

    func testSidebarPullRequestClickFallsThroughWhenClickabilityDisabled() throws {
        try assertSidebarPullRequestClickFallsThrough(clickabilityOverride: false, expectsPlainText: true)
    }

    private func assertSidebarPullRequestClickFallsThrough(
        clickabilityOverride: Bool?,
        expectsPlainText: Bool
    ) throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-sidebarHideAllDetails", "false",
            "-sidebarShowPullRequest", "true",
            "-browserOpenSidebarPullRequestLinksInCmuxBrowser", "true",
        ]
        if let clickabilityOverride {
            app.launchArguments += [
                "-sidebarMakePullRequestClickable",
                clickabilityOverride ? "true" : "false",
            ]
        }
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launch()

        XCTAssertTrue(
            pollUntil(timeout: 8.0) {
                guard app.state != .runningForeground else { return true }
                app.activate()
                return app.state == .runningForeground
            },
            "App did not reach runningForeground before UI interactions"
        )
        XCTAssertTrue(waitForSocketPong(timeout: 12.0), "Expected control socket at \(socketPath)")

        let mainWindowId = try XCTUnwrap(
            socketCommand("current_window")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let pullRequestWorkspaceId = try XCTUnwrap(
            socketCommand("current_workspace")?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let pullRequestPanelId = try XCTUnwrap(surfaceIDs(workspaceId: pullRequestWorkspaceId).first)
        let initialSurfaceCount = surfaceIDs(workspaceId: pullRequestWorkspaceId).count
        XCTAssertGreaterThan(initialSurfaceCount, 0, "Expected an initial surface in the PR workspace")

        let secondWorkspaceId = try XCTUnwrap(
            okUUID(from: socketCommand("new_workspace")),
            "Expected new_workspace to return a workspace ID"
        )
        XCTAssertEqual(
            socketCommand("report_pr \(pullRequestNumber) \(pullRequestURL) --tab=\(pullRequestWorkspaceId) --panel=\(pullRequestPanelId)"),
            "OK"
        )
        XCTAssertEqual(socketCommand("focus_window \(mainWindowId)"), "OK")
        XCTAssertEqual(socketCommand("select_workspace 1"), "OK")
        XCTAssertEqual(
            waitForCurrentWorkspace(secondWorkspaceId, timeout: 5.0),
            secondWorkspaceId,
            "Expected the second workspace to stay selected before clicking the PR row"
        )

        let pullRequestElement = try requirePullRequestElement(app: app, labelToken: "PR #\(pullRequestNumber)")
        if expectsPlainText {
            XCTAssertNotEqual(
                pullRequestElement.elementType,
                .button,
                "Default sidebar PR rendering should expose plain text, not a Button"
            )
            XCTAssertFalse(
                app.buttons["SidebarPullRequestRow"].exists,
                "Default sidebar PR rendering should not expose a Button with the PR row identifier"
            )
        }
        pullRequestElement.click()

        XCTAssertEqual(
            waitForCurrentWorkspace(pullRequestWorkspaceId, timeout: 5.0),
            pullRequestWorkspaceId,
            "Expected clicking the sidebar PR area to select the workspace row"
        )
        XCTAssertTrue(
            waitForSurfaceCountToStay(
                initialSurfaceCount,
                workspaceId: pullRequestWorkspaceId,
                timeout: 1.5
            ),
            "Expected disabling sidebar PR clickability to prevent opening a browser surface"
        )
    }

    private func deleteSidebarClickabilityDefault() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", defaultsDomain, "sidebarMakePullRequestClickable"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func requirePullRequestElement(
        app: XCUIApplication,
        labelToken: String
    ) throws -> XCUIElement {
        let buttonByIdentifier = app.buttons["SidebarPullRequestRow"]
        let otherByIdentifier = app.otherElements["SidebarPullRequestRow"]
        let staticTextByIdentifier = app.staticTexts["SidebarPullRequestRow"]
        let buttonByLabel = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", labelToken)).firstMatch

        let candidates = [
            buttonByIdentifier,
            otherByIdentifier,
            staticTextByIdentifier,
            buttonByLabel,
        ]

        for _ in 0..<20 {
            if let element = firstHittableElement(candidates: candidates) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        throw NSError(
            domain: "SidebarPullRequestInteractivityUITests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not find the sidebar PR row"]
        )
    }

    private func firstHittableElement(candidates: [XCUIElement]) -> XCUIElement? {
        for candidate in candidates where candidate.exists && candidate.isHittable {
            return candidate
        }
        return nil
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            socketCommand("ping") == "PONG"
        }
    }

    private func waitForCurrentWorkspace(_ expectedWorkspaceId: String, timeout: TimeInterval) -> String? {
        var current: String?
        let matched = pollUntil(timeout: timeout) {
            current = socketCommand("current_workspace")?.trimmingCharacters(in: .whitespacesAndNewlines)
            return current == expectedWorkspaceId
        }
        return matched ? current : nil
    }

    private func waitForSurfaceCountToStay(
        _ expectedCount: Int,
        workspaceId: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if surfaceIDs(workspaceId: workspaceId).count != expectedCount {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return surfaceIDs(workspaceId: workspaceId).count == expectedCount
    }

    private func surfaceIDs(workspaceId: String) -> [String] {
        guard let response = socketCommand("list_surfaces \(workspaceId)"),
              !response.isEmpty,
              !response.hasPrefix("No surfaces") else {
            return []
        }
        return response
            .split(separator: "\n")
            .compactMap { line in
                guard let range = line.range(of: ": ") else { return nil }
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private func okUUID(from response: String?) -> String? {
        guard let response, response.hasPrefix("OK ") else { return nil }
        let value = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: value) != nil ? value : nil
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendLine(command)
    }

    private func pollUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
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
