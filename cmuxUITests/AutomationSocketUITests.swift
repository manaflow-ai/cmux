import XCTest
import Foundation

final class AutomationSocketUITests: XCTestCase {
    private struct RenderStatsSnapshot: CustomStringConvertible {
        let panelId: String
        let layerContentsKey: String
        let inWindow: Bool
        let presentCount: Int

        var hasPresentedFirstFrame: Bool {
            inWindow && layerContentsKey != "nil" && presentCount > 0
        }

        var description: String {
            "panelId=\(panelId) inWindow=\(inWindow) presentCount=\(presentCount) layerContentsKey=\(layerContentsKey)"
        }
    }

    private var socketPath = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"
    private let launchTag = "ui-tests-automation-socket"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        resetSocketDefaults()
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

    func testRapidWorkspaceCreationPresentsFirstFrameWithoutWorkspaceSwitch() {
        let app = configuredApp(mode: "cmuxOnly")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for workspace first-frame test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0) else {
            XCTFail("Expected control socket to exist for workspace first-frame test")
            return
        }
        socketPath = resolvedPath

        XCTAssertTrue(
            waitForSocketPong(timeout: 8.0),
            "Expected control socket to respond to ping at \(socketPath)"
        )

        var seenWorkspaceIds: Set<String> = []
        var excludedPanelIds: Set<String> = []
        var createdPanelIds: Set<String> = []

        if let baselineStats = currentRenderStats() {
            excludedPanelIds.insert(baselineStats.panelId)
        }

        for index in 0..<10 {
            guard let workspaceId = okUUID(from: socketCommand("new_workspace")) else {
                XCTFail(
                    "Expected new_workspace to return a workspace ID on iteration \(index).\n\(debugWorkspaceCreationState())"
                )
                return
            }
            seenWorkspaceIds.insert(workspaceId)

            guard let stats = waitForSelectedWorkspaceFirstFrame(
                timeout: 5.0,
                excludingPanelIds: excludedPanelIds
            ) else {
                XCTFail(
                    "Expected newly created workspace to present its first frame on iteration \(index).\n" +
                    "workspaceId=\(workspaceId)\n\(debugWorkspaceCreationState())"
                )
                return
            }

            XCTAssertTrue(
                stats.hasPresentedFirstFrame,
                "Expected selected workspace to have a visible IOSurface-backed first frame. stats=\(stats)"
            )
            excludedPanelIds.insert(stats.panelId)
            createdPanelIds.insert(stats.panelId)
        }

        XCTAssertEqual(seenWorkspaceIds.count, 10, "Expected each new_workspace call to create a distinct workspace")
        XCTAssertEqual(createdPanelIds.count, 10, "Expected each created workspace to expose a distinct focused terminal panel")
        app.terminate()
    }

    private func configuredApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", mode, "-cmuxWelcomeShown", "YES"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        // Debug launches require a tag outside reload.sh; provide one in UITests so CI
        // does not fail with "Application ... does not have a process ID".
        app.launchEnvironment["CMUX_TAG"] = launchTag
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

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in predicate() },
            object: nil
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

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("ping") == "PONG"
        }
    }

    private func waitForSelectedWorkspaceFirstFrame(
        timeout: TimeInterval,
        excludingPanelIds: Set<String>
    ) -> RenderStatsSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: RenderStatsSnapshot?

        while Date() < deadline {
            if let stats = currentRenderStats() {
                latest = stats
                if !excludingPanelIds.contains(stats.panelId), stats.hasPresentedFirstFrame {
                    return stats
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        return latest
    }

    private func currentRenderStats() -> RenderStatsSnapshot? {
        guard let response = socketCommand("render_stats"),
              response.hasPrefix("OK ") else {
            return nil
        }
        let payload = String(response.dropFirst(3))
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let panelId = object["panelId"] as? String,
              let layerContentsKey = object["layerContentsKey"] as? String,
              let inWindow = object["inWindow"] as? Bool else {
            return nil
        }

        return RenderStatsSnapshot(
            panelId: panelId,
            layerContentsKey: layerContentsKey,
            inWindow: inWindow,
            presentCount: object["presentCount"] as? Int ?? 0
        )
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendLine(command)
    }

    private func okUUID(from response: String?) -> String? {
        guard let response,
              response.hasPrefix("OK ") else {
            return nil
        }
        let value = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: value) != nil else { return nil }
        return value
    }

    private func debugWorkspaceCreationState() -> String {
        let currentWorkspace = socketCommand("current_workspace") ?? "<nil>"
        let workspaces = socketCommand("list_workspaces") ?? "<nil>"
        let surfaces = socketCommand("list_surfaces") ?? "<nil>"
        let health = socketCommand("surface_health") ?? "<nil>"
        let renderStats = socketCommand("render_stats") ?? "<nil>"

        return [
            "current_workspace: \(currentWorkspace)",
            "list_workspaces: \(workspaces)",
            "list_surfaces: \(surfaces)",
            "surface_health: \(health)",
            "render_stats: \(renderStats)",
        ].joined(separator: "\n")
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
