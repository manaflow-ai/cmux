import Network
import XCTest

final class cmuxMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStackAuthEntryUsesStableIdentifiers() throws {
        let app = launchApp(mockData: false, clearAuth: true)

        XCTAssertTrue(app.buttons["signin.apple"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["signin.google"].exists)

        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.exists)

        let emailCodeButton = app.buttons["signin.emailCode"]
        XCTAssertTrue(emailCodeButton.exists)
        XCTAssertFalse(emailCodeButton.isEnabled)

        try typeText("dogfood@example.com", into: emailField, in: app)
        XCTAssertTrue(emailCodeButton.isEnabled)
    }

    @MainActor
    func testAddDeviceManualHostValidationUsesStableIdentifiers() throws {
        let app = launchAddDeviceApp()

        XCTAssertTrue(app.otherElements["MobileAddDeviceForm"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.textFields["MobileAddDeviceNameField"].exists)
        XCTAssertTrue(app.textFields["MobileAddDeviceHostField"].exists)
        XCTAssertTrue(app.textFields["MobileAddDevicePortField"].exists)
        XCTAssertTrue(app.buttons["MobileScanQRCodeButton"].exists)

        let pairButton = app.buttons["MobilePairButton"]
        XCTAssertTrue(pairButton.exists)
        XCTAssertFalse(pairButton.isEnabled)

        try typeText("dev box.local", into: app.textFields["MobileAddDeviceHostField"], in: app)
        tap(pairButton, in: app)
        assertPairingError(contains: "Enter a host or IP address", in: app)

        try replaceText("127.0.0.1", in: app.textFields["MobileAddDeviceHostField"], app: app)
        try replaceText("70000", in: app.textFields["MobileAddDevicePortField"], app: app)
        tap(pairButton, in: app)
        assertPairingError(contains: "Enter a port from 1 to 65535", in: app)
    }

    @MainActor
    func testManualHostConnectsAndNavigatesToWorkspace() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)

        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 6))
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        assertTerminalRow(2, label: "host: UI Test Mac", in: app)
    }

    @MainActor
    func testWorkspaceToolbarCreatesWorkspaceAndTerminal() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        tap(app.buttons["MobileTerminalNewWorkspaceButton"], in: app)
        assertTerminalRow(1, label: "workspace: Workspace 3", in: app)
        assertTerminalRow(2, label: "terminal: Terminal 1", in: app)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        tap(app.buttons["MobileNewTerminalMenuItem"], in: app)
        assertTerminalRow(1, label: "workspace: Workspace 3", in: app)
        assertTerminalRow(2, label: "terminal: Terminal 2", in: app)
    }

    @MainActor
    func testTerminalDropdownSwitchesToAlternateScreenSnapshot() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        tap(app.buttons["MobileTerminalMenuItem-terminal-tui"], in: app)

        assertTerminalRow(0, label: "LAZYGIT", in: app)
        assertTerminalRow(1, label: "files branches log", in: app)
        assertTerminalRow(3, label: "q quit", in: app)
    }

    @MainActor
    func testTUITerminalUsesAvailableViewportAndResizes() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)
        try switchToTUITerminal(in: app)

        XCUIDevice.shared.orientation = .portrait
        let portraitFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            frame.height > frame.width
        }
        assertTerminalSurfaceUsesAvailableViewport(portraitFrame, in: app)
        assertTerminalRow(0, label: "LAZYGIT", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            app.isLandscape && frame.width > portraitFrame.width + 80
        }
        assertTerminalSurfaceUsesAvailableViewport(landscapeFrame, in: app)
        XCTAssertLessThan(
            landscapeFrame.height,
            portraitFrame.height - 40,
            "Terminal surface should shrink vertically after rotating to landscape."
        )

        XCUIDevice.shared.orientation = .portrait
        let restoredPortraitFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            app.isPortrait && frame.height > landscapeFrame.height + 40
        }
        assertTerminalSurfaceUsesAvailableViewport(restoredPortraitFrame, in: app)
        assertTerminalRow(0, label: "LAZYGIT", in: app)
    }

    @MainActor
    private func launchConnectedApp(port: UInt16) throws -> XCUIApplication {
        let app = launchAddDeviceApp(environment: [
            "CMUX_UITEST_ADD_DEVICE_NAME": "UI Test Mac",
            "CMUX_UITEST_ADD_DEVICE_HOST": "127.0.0.1",
            "CMUX_UITEST_ADD_DEVICE_PORT": String(port),
        ])
        tap(app.buttons["MobilePairButton"], in: app)
        waitForWorkspaceShell(in: app)
        return app
    }

    @MainActor
    private func launchAddDeviceApp(environment: [String: String] = [:]) -> XCUIApplication {
        let app = launchApp(mockData: true, environment: environment)
        XCTAssertTrue(app.otherElements["MobileAddDeviceForm"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func launchApp(
        mockData: Bool,
        clearAuth: Bool = false,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = mockData ? "1" : "0"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        if clearAuth {
            app.launchEnvironment["CMUX_UITEST_CLEAR_AUTH"] = "1"
        }
        app.launch()
        return app
    }

    @MainActor
    private func openSelectedWorkspaceIfNeeded(_ app: XCUIApplication) throws {
        if app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 1) {
            return
        }

        let row = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.tap()
    }

    @MainActor
    private func assertTerminalRow(
        _ index: Int,
        label expectedLabel: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = terminalRow(index, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 6), file: file, line: line)
        let predicate = NSPredicate(format: "label == %@", expectedLabel)
        let labelExpectation = XCTNSPredicateExpectation(predicate: predicate, object: row)
        let result = XCTWaiter.wait(for: [labelExpectation], timeout: 6)
        XCTAssertEqual(result, .completed, file: file, line: line)
        XCTAssertEqual(row.label, expectedLabel, file: file, line: line)
    }

    @MainActor
    private func waitForWorkspaceShell(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let workspaceList = app.otherElements["MobileWorkspaceList"]
        let workspaceRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        let terminalSurface = app.otherElements["MobileTerminalSurface"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                workspaceList.exists || workspaceRow.exists || terminalSurface.exists
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: 30)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    @MainActor
    private func switchToTUITerminal(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        tap(app.buttons["MobileTerminalDropdown"], in: app, file: file, line: line)
        tap(app.buttons["MobileTerminalMenuItem-terminal-tui"], in: app, file: file, line: line)
        assertTerminalRow(0, label: "LAZYGIT", in: app, file: file, line: line)
    }

    @MainActor
    private func waitForTerminalSurfaceFrame(
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        matching predicate: @escaping (CGRect) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGRect {
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6), file: file, line: line)

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                return predicate(element.frame)
            },
            object: surface
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Timed out waiting for terminal surface resize. Last frame: \(surface.frame)",
            file: file,
            line: line
        )
        return surface.frame
    }

    @MainActor
    private func assertTerminalSurfaceUsesAvailableViewport(
        _ frame: CGRect,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewport = availableTerminalViewport(in: app)
        let horizontalTolerance: CGFloat = 12
        let bottomTolerance: CGFloat = 4
        let topChromeBudget = max(CGFloat(150), viewport.height * 0.22)

        XCTAssertLessThanOrEqual(
            abs(frame.minX - viewport.minX),
            horizontalTolerance,
            "Terminal surface should start at the available detail viewport edge. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.maxX,
            viewport.maxX - horizontalTolerance,
            "Terminal surface should reach the available viewport trailing edge. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxX,
            viewport.maxX + horizontalTolerance,
            "Terminal surface should not overflow the available viewport trailing edge. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.maxY,
            viewport.maxY - bottomTolerance,
            "Terminal surface should reach the bottom of the viewport without a send/input bar. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.minY - viewport.minY,
            topChromeBudget,
            "Terminal surface should only leave room for navigation chrome above it. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.height,
            viewport.height - topChromeBudget - bottomTolerance,
            "Terminal surface should use the vertical space below the navigation bar. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func availableTerminalViewport(in app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch
        let windowFrame = window.exists ? window.frame : app.frame
        let workspaceList = app.otherElements["MobileWorkspaceList"]
        guard workspaceList.exists,
              workspaceList.frame.width > 180,
              workspaceList.frame.maxX < windowFrame.maxX - 180 else {
            return windowFrame
        }

        return CGRect(
            x: workspaceList.frame.maxX,
            y: windowFrame.minY,
            width: windowFrame.maxX - workspaceList.frame.maxX,
            height: windowFrame.height
        )
    }

    @MainActor
    private func assertPairingError(
        contains expectedText: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let error = app.staticTexts["MobilePairingError"]
        XCTAssertTrue(error.waitForExistence(timeout: 4), file: file, line: line)
        XCTAssertTrue(error.label.contains(expectedText), file: file, line: line)
    }

    @MainActor
    private func terminalRow(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["MobileTerminalRow-\(index)"]
    }

    @MainActor
    private func typeText(_ text: String, into element: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        element.tap()
        element.typeText(text)
        dismissKeyboard(in: app)
    }

    @MainActor
    private func replaceText(_ text: String, in element: XCUIElement, app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        element.tap()
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        element.typeText(text)
        dismissKeyboard(in: app)
    }

    @MainActor
    private func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 4), file: file, line: line)
        if !element.isHittable {
            dismissKeyboard(in: app)
        }
        let predicate = NSPredicate(format: "hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: 4)
        if result != .completed {
            let frame = element.frame
            XCTAssertFalse(frame.isNull || frame.isEmpty || frame.origin.x.isNaN || frame.origin.y.isNaN, file: file, line: line)
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                .tap()
            return
        }
        element.tap()
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else {
            return
        }
        for label in ["Done", "Return", "Next"] {
            let button = app.keyboards.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }
}

private final class MobileSyncMockHostServer: @unchecked Sendable {
    private struct Workspace {
        var id: String
        var title: String
        var currentDirectory: String
        var terminals: [Terminal]
    }

    private struct Terminal {
        var id: String
        var title: String
        var currentDirectory: String
        var lines: [String]
        var activeScreen: String = "primary"
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cmux.ios-ui-tests.mobile-sync-server")
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []
    private var selectedWorkspaceID = "workspace-main"
    private var selectedTerminalID = "terminal-build"
    private var streamOffset: UInt64 = 1
    private var workspaces: [Workspace] = [
        Workspace(
            id: "workspace-main",
            title: "cmux",
            currentDirectory: "~/cmux",
            terminals: [
                Terminal(
                    id: "terminal-build",
                    title: "Build",
                    currentDirectory: "~/cmux",
                    lines: [
                        "$ cmux ios status",
                        "Mobile Core: connected",
                        "host: UI Test Mac",
                        "route: debugLoopback",
                    ]
                ),
                Terminal(
                    id: "terminal-tui",
                    title: "TUI",
                    currentDirectory: "~/cmux",
                    lines: [
                        "LAZYGIT",
                        "files branches log",
                        "main feat-ios clean",
                        "q quit",
                    ],
                    activeScreen: "alternate"
                ),
            ]
        ),
        Workspace(
            id: "workspace-docs",
            title: "Docs",
            currentDirectory: "~/cmux/docs",
            terminals: [
                Terminal(
                    id: "terminal-notes",
                    title: "Notes",
                    currentDirectory: "~/cmux/docs",
                    lines: [
                        "$ rg CMUXMobileCore docs",
                        "docs/ios-swift-mobile-plan.md:iOS shell depends on CMUXMobileCore.",
                    ]
                ),
            ]
        ),
    ]

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            for connection in self.connections {
                connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                readyContinuation?.resume(returning: port)
            } else {
                readyContinuation?.resume(throwing: serverError("Listener did not publish a port."))
            }
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
        case .cancelled:
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let payload = Self.nextFrame(from: &nextBuffer) {
                self.respond(to: payload, on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func respond(to payload: Data, on connection: NWConnection) {
        do {
            let responseFrame = try makeResponseFrame(for: payload)
            connection.send(
                content: responseFrame,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    connection.cancel()
                }
            )
        } catch {
            connection.cancel()
        }
    }

    private func makeResponseFrame(for payload: Data) throws -> Data {
        guard let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let method = request["method"] as? String else {
            throw serverError("Invalid request.")
        }

        let id = request["id"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]

        switch method {
        case "workspace.list":
            result = workspaceListResult()
        case "workspace.create":
            result = createWorkspaceResult()
        case "terminal.create":
            result = createTerminalResult(params: params)
        case "terminal.snapshot":
            result = terminalSnapshotResult(params: params)
        default:
            result = [:]
        }

        let envelope: [String: Any] = [
            "id": id,
            "ok": true,
            "result": result,
        ]
        let responsePayload = try JSONSerialization.data(withJSONObject: envelope)
        return Self.frame(responsePayload)
    }

    private func createWorkspaceResult() -> [String: Any] {
        let nextIndex = workspaces.count + 1
        let workspaceID = "workspace-\(nextIndex)"
        let terminalID = "\(workspaceID)-terminal-1"
        let workspace = Workspace(
            id: workspaceID,
            title: "Workspace \(nextIndex)",
            currentDirectory: "~/workspace-\(nextIndex)",
            terminals: [
                Terminal(
                    id: terminalID,
                    title: "Terminal 1",
                    currentDirectory: "~/workspace-\(nextIndex)",
                    lines: [
                        "$ cmux ios",
                        "workspace: Workspace \(nextIndex)",
                        "terminal: Terminal 1",
                    ]
                ),
            ]
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspaceID
        selectedTerminalID = terminalID

        var result = workspaceListResult()
        result["created_workspace_id"] = workspaceID
        return result
    }

    private func createTerminalResult(params: [String: Any]) -> [String: Any] {
        let workspaceID = params["workspace_id"] as? String ?? selectedWorkspaceID
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return workspaceListResult()
        }

        let terminalIndex = workspaces[workspaceIndex].terminals.count + 1
        let terminalID = "\(workspaceID)-terminal-\(terminalIndex)"
        let terminal = Terminal(
            id: terminalID,
            title: "Terminal \(terminalIndex)",
            currentDirectory: workspaces[workspaceIndex].currentDirectory,
            lines: [
                "$ cmux ios",
                "workspace: \(workspaces[workspaceIndex].title)",
                "terminal: Terminal \(terminalIndex)",
            ]
        )
        workspaces[workspaceIndex].terminals.append(terminal)
        selectedWorkspaceID = workspaceID
        selectedTerminalID = terminalID

        var result = workspaceListResult()
        result["created_terminal_id"] = terminalID
        return result
    }

    private func terminalSnapshotResult(params: [String: Any]) -> [String: Any] {
        let terminalID = params["surface_id"] as? String ?? selectedTerminalID
        selectedTerminalID = terminalID
        if let workspace = workspaces.first(where: { workspace in
            workspace.terminals.contains(where: { $0.id == terminalID })
        }) {
            selectedWorkspaceID = workspace.id
        }
        let terminal = workspaces
            .lazy
            .flatMap(\.terminals)
            .first { $0.id == terminalID }
            ?? workspaces[0].terminals[0]
        streamOffset += 1
        return [
            "surface_id": terminal.id,
            "snapshot": snapshot(for: terminal),
        ]
    }

    private func workspaceListResult() -> [String: Any] {
        [
            "workspaces": workspaces.map { workspace in
                [
                    "id": workspace.id,
                    "title": workspace.title,
                    "current_directory": workspace.currentDirectory,
                    "is_selected": workspace.id == selectedWorkspaceID,
                    "terminals": workspace.terminals.map { terminal in
                        [
                            "id": terminal.id,
                            "title": terminal.title,
                            "current_directory": terminal.currentDirectory,
                            "is_focused": terminal.id == selectedTerminalID,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
    }

    private func snapshot(for terminal: Terminal) -> [String: Any] {
        let visibleRows = Array((terminal.lines + Array(repeating: "", count: 6)).prefix(6))
            .map { Self.row($0) }
        return [
            "schemaVersion": 1,
            "terminalID": terminal.id,
            "gridSize": [
                "columns": 48,
                "rows": 6,
            ],
            "activeScreen": terminal.activeScreen,
            "scrollbackRows": [],
            "visibleRows": visibleRows,
            "cursor": [
                "column": 0,
                "row": 5,
                "isVisible": false,
                "style": "block",
            ],
            "modes": [
                "bracketedPaste": false,
                "applicationCursorKeys": false,
                "applicationKeypad": false,
                "mouseTracking": terminal.activeScreen == "alternate",
                "cursorVisible": false,
            ],
            "streamOffset": streamOffset,
            "generatedAt": "1970-01-01T00:00:00Z",
        ]
    }

    private static func row(_ text: String, columns: Int = 48) -> [String: Any] {
        let visibleCells = text.prefix(columns).map { character in
            [
                "text": String(character),
                "width": "narrow",
                "style": [
                    "bold": false,
                    "italic": false,
                    "dim": false,
                    "inverse": false,
                    "underline": "none",
                ],
            ] as [String: Any]
        }
        let blankCell = [
            "text": "",
            "width": "narrow",
            "style": [
                "bold": false,
                "italic": false,
                "dim": false,
                "inverse": false,
                "underline": "none",
            ],
        ] as [String: Any]
        let cells = visibleCells + Array(repeating: blankCell, count: max(0, columns - visibleCells.count))
        return [
            "cells": cells,
            "isWrapped": false,
        ]
    }

    private static func nextFrame(from buffer: inout Data) -> Data? {
        let headerByteCount = 4
        guard buffer.count >= headerByteCount else {
            return nil
        }
        let payloadLength = Int(buffer.prefix(headerByteCount).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        })
        guard buffer.count >= headerByteCount + payloadLength else {
            return nil
        }
        let payloadStart = headerByteCount
        let payloadEnd = payloadStart + payloadLength
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        buffer.removeSubrange(0..<payloadEnd)
        return payload
    }

    private static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    private func serverError(_ message: String) -> NSError {
        NSError(domain: "MobileSyncMockHostServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension XCUIApplication {
    var isLandscape: Bool {
        let frame = windows.firstMatch.exists ? windows.firstMatch.frame : self.frame
        return frame.width > frame.height
    }

    var isPortrait: Bool {
        let frame = windows.firstMatch.exists ? windows.firstMatch.frame : self.frame
        return frame.height > frame.width
    }
}
