import Foundation
import XCTest

/// End-to-end regression coverage for issue #9518. The control socket builds
/// real main-area and right-sidebar Dock browser trees, then `simulate_shortcut`
/// enters the same AppDelegate matcher/dispatcher used by keyboard events. This
/// keeps the assertions deterministic on headless hosted runners while still
/// exercising the production focus and closed-panel paths.
final class DockShortcutRoutingUITests: XCTestCase {
    private struct CreatedSurface {
        let id: String
        let containerID: String
    }

    private struct BrowserTabState: Equatable {
        let id: String
        let url: String
    }

    private var appProcess: Process?
    private var isolatedHome: URL!
    private var appLogPath = ""
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let token = UUID().uuidString
        isolatedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-ui-test-dock-shortcuts-\(token)",
            isDirectory: true
        )
        appLogPath = isolatedHome.appendingPathComponent("app.log").path
        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dock-\(token.prefix(8)).sock")
            .path
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        removeSocketFiles()
    }

    override func tearDown() {
        terminateAppProcess()
        removeSocketFiles()
        if let isolatedHome {
            try? FileManager.default.removeItem(at: isolatedHome)
        }
        super.tearDown()
    }

    func testCmdLFocusesDockBrowserAddressBar() throws {
        try launchIsolatedApp()

        let mainWorkspaceID = try XCTUnwrap(currentWorkspaceID())
        let mainBrowser = try createBrowserSurface(
            url: "https://main-address.example/",
            containerID: mainWorkspaceID
        )
        let dockBrowser = try createBrowserSurface(
            url: "https://dock-address.example/",
            placement: "dock"
        )
        XCTAssertNotEqual(
            dockBrowser.containerID,
            mainWorkspaceID,
            "The regression needs independent main-workspace and window-Dock containers"
        )

        try focusDockBrowser(dockBrowser)
        XCTAssertTrue(
            waitUntil(timeout: 5.0) { self.focusedAddressBarSurfaceID() == nil },
            "Expected the Dock host, not an address bar, to own focus before Cmd+L"
        )

        simulateShortcut("cmd+l")

        XCTAssertTrue(
            waitUntil(timeout: 8.0) { self.focusedAddressBarSurfaceID() != nil },
            "Cmd+L never focused any browser address bar"
        )
        let focusedSurfaceID = focusedAddressBarSurfaceID()
        XCTAssertEqual(
            focusedSurfaceID,
            dockBrowser.id,
            "Cmd+L should focus the Dock browser address bar, not the main area's. " +
                "dock=\(dockBrowser.id) main=\(mainBrowser.id) actual=\(focusedSurfaceID ?? "nil")"
        )
        XCTAssertNotEqual(
            focusedSurfaceID,
            mainBrowser.id,
            "Cmd+L incorrectly focused the main-area browser address bar"
        )
    }

    func testCmdShiftTReopensDockBrowserWithoutChangingMainArea() throws {
        try launchIsolatedApp()

        let mainWorkspaceID = try XCTUnwrap(currentWorkspaceID())
        let mainKept = try createBrowserSurface(
            url: "https://main-kept.example/",
            containerID: mainWorkspaceID
        )
        let mainClosedURL = "https://main-closed.example/"
        let mainClosed = try createBrowserSurface(
            url: mainClosedURL,
            containerID: mainWorkspaceID
        )
        try closeSurface(mainClosed)

        let dockClosedURL = "https://dock-closed.example/"
        let dockClosed = try createBrowserSurface(url: dockClosedURL, placement: "dock")
        let dockRemaining = try createBrowserSurface(
            url: "https://dock-remaining.example/",
            placement: "dock"
        )
        XCTAssertEqual(dockClosed.containerID, dockRemaining.containerID)
        XCTAssertNotEqual(
            dockRemaining.containerID,
            mainWorkspaceID,
            "The regression needs independent main-workspace and window-Dock containers"
        )
        try closeSurface(dockClosed)
        try focusDockBrowser(dockRemaining)

        let mainTabsBefore = try XCTUnwrap(browserTabs(
            workspaceID: mainWorkspaceID,
            anchorSurfaceID: mainKept.id
        ))
        let dockTabsBefore = try XCTUnwrap(browserTabs(anchorSurfaceID: dockRemaining.id))
        XCTAssertEqual(mainTabsBefore.map(\.id), [mainKept.id])
        XCTAssertFalse(mainTabsBefore.contains { urlHost($0.url) == urlHost(mainClosedURL) })
        XCTAssertEqual(dockTabsBefore.map(\.id), [dockRemaining.id])
        XCTAssertFalse(dockTabsBefore.contains { urlHost($0.url) == urlHost(dockClosedURL) })

        simulateShortcut("cmd+shift+t")

        XCTAssertTrue(
            waitUntil(timeout: 10.0) {
                let mainCount = self.browserTabs(
                    workspaceID: mainWorkspaceID,
                    anchorSurfaceID: mainKept.id
                )?.count
                let dockCount = self.browserTabs(anchorSurfaceID: dockRemaining.id)?.count
                return mainCount != mainTabsBefore.count || dockCount != dockTabsBefore.count
            },
            "Cmd+Shift+T did not change either browser tree"
        )

        let mainTabsAfter = try XCTUnwrap(browserTabs(
            workspaceID: mainWorkspaceID,
            anchorSurfaceID: mainKept.id
        ))
        let dockTabsAfter = try XCTUnwrap(browserTabs(anchorSurfaceID: dockRemaining.id))
        XCTAssertEqual(
            mainTabsAfter.map(\.id),
            mainTabsBefore.map(\.id),
            "Cmd+Shift+T should leave the main-area browser tabs unchanged. " +
                "before=\(mainTabsBefore) after=\(mainTabsAfter)"
        )
        XCTAssertFalse(
            mainTabsAfter.contains { urlHost($0.url) == urlHost(mainClosedURL) },
            "Cmd+Shift+T incorrectly reopened the main area's closed browser"
        )
        XCTAssertEqual(dockTabsAfter.count, 2)
        XCTAssertTrue(dockTabsAfter.contains { $0.id == dockRemaining.id })
        XCTAssertTrue(
            dockTabsAfter.contains { urlHost($0.url) == urlHost(dockClosedURL) },
            "Cmd+Shift+T should restore the closed Dock browser. " +
                "before=\(dockTabsBefore) after=\(dockTabsAfter)"
        )
    }

    // MARK: - App and control socket

    private func launchIsolatedApp() throws {
        // Socket-driven coverage does not need XCUI accessibility. Launch the
        // binary directly so headless runners do not abort the test while
        // XCUIApplication spends 60 seconds trying to foreground the app.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolveAppBinaryPath())
        process.arguments = [
            "-socketControlMode", "allowAll",
            "-rightSidebar.beta.dock.enabled", "YES",
            "-browserDisabledOverride", "NO",
            "-menuBarOnly", "NO",
            "-NSAppSleepDisabled", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = isolatedHome.path
        environment["CFFIXED_USER_HOME"] = isolatedHome.path
        environment["XDG_CONFIG_HOME"] = isolatedHome
            .appendingPathComponent(".config", isDirectory: true).path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SOCKET_ENABLE"] = "1"
        environment["CMUX_SOCKET_MODE"] = "allowAll"
        environment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        environment["CMUX_UI_TEST_MODE"] = "1"
        environment["CMUX_UI_TEST_PROCESS"] = "1"
        environment["CMUX_TAG"] = "ui-dock-shortcuts-\(UUID().uuidString.prefix(8))"
        process.environment = environment

        _ = FileManager.default.createFile(atPath: appLogPath, contents: nil)
        let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: appLogPath))
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        appProcess = process

        XCTAssertTrue(
            waitForControlSocketReady(
                socketPath: socketPath,
                pingTimeout: 20.0,
                pingReturnsPong: { self.socketCommand("ping") == "PONG" }
            ),
            "Control socket never answered ping at \(socketPath). " +
                "app=\(appProcessDiagnostics()) log=\(appLogTail())"
        )
        XCTAssertEqual(socketCommand("activate_app", responseTimeout: 10.0), "OK")
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
            domain: "DockShortcutRoutingUITests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "App binary not found at \(binaryPaths.joined(separator: " or ")). " +
                    "testBundle=\(testBundle.bundleURL.path)"
            ]
        )
    }

    private func terminateAppProcess() {
        guard let process = appProcess else { return }
        appProcess = nil
        guard process.isRunning else { return }
        process.terminate()
        _ = waitUntil(timeout: 5.0) { !process.isRunning }
        if process.isRunning {
            process.interrupt()
        }
    }

    private func appProcessDiagnostics() -> String {
        guard let process = appProcess else { return "not-launched" }
        let status = process.isRunning ? "running" : String(process.terminationStatus)
        return "pid=\(process.processIdentifier) running=\(process.isRunning) status=\(status)"
    }

    private func appLogTail() -> String {
        guard let contents = try? String(contentsOfFile: appLogPath, encoding: .utf8) else {
            return "<missing>"
        }
        return String(contents.suffix(2_000))
    }

    private func currentWorkspaceID() -> String? {
        guard let reply = socketCommand("current_workspace"), UUID(uuidString: reply) != nil else {
            return nil
        }
        return reply
    }

    private func createBrowserSurface(
        url: String,
        placement: String? = nil,
        containerID: String? = nil
    ) throws -> CreatedSurface {
        var params: [String: Any] = [
            "type": "browser",
            "url": url,
            "focus": true,
        ]
        if let placement { params["placement"] = placement }
        if let containerID { params["workspace_id"] = containerID }

        let result = try XCTUnwrap(
            socketResult(method: "surface.create", params: params),
            "surface.create failed for \(url): \(String(describing: lastSocketEnvelope))"
        )
        let isDock = placement == "dock"
        let idKey = isDock ? "dock_surface_id" : "surface_id"
        let surfaceID = try XCTUnwrap(result[idKey] as? String)
        let resolvedContainerID = try XCTUnwrap(result["workspace_id"] as? String)
        return CreatedSurface(id: surfaceID, containerID: resolvedContainerID)
    }

    private func closeSurface(_ surface: CreatedSurface) throws {
        let result = try XCTUnwrap(socketResult(
            method: "surface.close",
            params: [
                "workspace_id": surface.containerID,
                "surface_id": surface.id,
            ]
        ))
        XCTAssertEqual(result["surface_id"] as? String, surface.id)
    }

    private func focusDockBrowser(_ surface: CreatedSurface) throws {
        _ = try XCTUnwrap(socketResult(
            method: "surface.focus",
            params: [
                "workspace_id": surface.containerID,
                "surface_id": surface.id,
            ]
        ))
        XCTAssertTrue(
            waitUntil(timeout: 10.0) {
                self.socketResult(
                    method: "browser.focus_webview",
                    params: ["surface_id": surface.id]
                )?["focused"] as? Bool == true
            },
            "Dock browser WebView never became first responder: \(surface.id)"
        )

        // Leave the selected Dock browser intact, but move AppKit focus to the
        // Dock host. This is the ownership signal used while first-responder
        // updates lag or the host itself receives the shortcut.
        let sidebarResult = try XCTUnwrap(socketResult(
            method: "debug.right_sidebar.focus",
            params: [
                "mode": "dock",
                "window_id": surface.containerID,
                "focus_first_item": false,
            ]
        ))
        XCTAssertEqual(sidebarResult["active_mode"] as? String, "dock")
        XCTAssertEqual(sidebarResult["focus_applied"] as? Bool, true)
    }

    private func simulateShortcut(_ combo: String) {
        let reply = socketCommand("simulate_shortcut \(combo)", responseTimeout: 30.0)
        XCTAssertEqual(reply, "OK", "simulate_shortcut \(combo) failed: \(reply ?? "nil")")
    }

    // MARK: - State assertions

    private func focusedAddressBarSurfaceID() -> String? {
        socketResult(method: "debug.browser.address_bar_focused", params: [:])?["focused_surface_id"] as? String
    }

    private func browserTabs(
        workspaceID: String? = nil,
        anchorSurfaceID: String
    ) -> [BrowserTabState]? {
        var params: [String: Any] = ["surface_id": anchorSurfaceID]
        if let workspaceID { params["workspace_id"] = workspaceID }
        guard let result = socketResult(
            method: "browser.tab.list",
            params: params
        ), let tabs = result["tabs"] as? [[String: Any]] else {
            return nil
        }
        return tabs.compactMap { tab in
            guard let id = tab["id"] as? String, let url = tab["url"] as? String else {
                return nil
            }
            return BrowserTabState(id: id, url: url)
        }
    }

    private func urlHost(_ string: String) -> String? {
        URL(string: string)?.host
    }

    // MARK: - Socket plumbing

    private var lastSocketEnvelope: [String: Any]?

    private func socketCommand(_ command: String, responseTimeout: TimeInterval = 5.0) -> String? {
        controlSocketCommandViaNetcat(
            command,
            socketPath: socketPath,
            responseTimeout: responseTimeout
        )
    }

    private func socketResult(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        let envelope = controlSocketJSONViaNetcat(
            request,
            socketPath: socketPath,
            responseTimeout: 10.0
        )
        lastSocketEnvelope = envelope
        guard envelope?["ok"] as? Bool == true else { return nil }
        return envelope?["result"] as? [String: Any]
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }

    private func removeSocketFiles() {
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: "\(socketPath).lock")
    }
}
