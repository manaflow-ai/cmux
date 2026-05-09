import Foundation
import Network
import UIKit
import XCTest

final class cmuxMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSignInPairingAndWorkspaceShell() throws {
        let app = launchApp()

        XCTAssertTrue(app.buttons["MobileSignInButton"].waitForExistence(timeout: 8))
        app.buttons["MobileSignInButton"].tap()

        XCTAssertTrue(app.textFields["MobilePairingCodeField"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["MobileScanQRCodeButton"].isEnabled)
        app.textFields["MobilePairingCodeField"].tap()
        app.textFields["MobilePairingCodeField"].typeText("debug")
        app.buttons["MobileConnectButton"].tap()

        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.staticTexts["cmux-macbook"].exists)
        XCTAssertTrue(app.staticTexts["Mobile Sync: enabled"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testCreateWorkspaceAndTerminalFromShell() throws {
        let app = launchApp()
        try connect(app)

        let newWorkspaceButton = app.buttons.matching(identifier: "MobileNewWorkspaceButton").firstMatch
        XCTAssertTrue(newWorkspaceButton.waitForExistence(timeout: 4))
        newWorkspaceButton.tap()
        XCTAssertTrue(app.staticTexts["Workspace 3"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["terminal: Terminal 1"].waitForExistence(timeout: 4))

        app.buttons["MobileTerminalDropdown"].tap()
        let newTerminal = app.buttons["MobileNewTerminalMenuItem"]
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 4))
        newTerminal.tap()

        XCTAssertTrue(app.staticTexts["terminal: Terminal 2"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testTerminalDropdownSwitchesVisibleTerminal() throws {
        let app = launchApp()
        try connect(app)

        app.buttons["MobileTerminalDropdown"].tap()
        let agentTerminal = app.buttons["MobileTerminalMenuItem-terminal-agent"]
        XCTAssertTrue(agentTerminal.waitForExistence(timeout: 4))
        agentTerminal.tap()

        XCTAssertTrue(app.staticTexts["$ git status --short"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["## feat-ios-minimal-shell"].exists)
    }

    @MainActor
    func testTerminalDropdownSwitchesToAlternateScreenSnapshot() throws {
        let app = launchApp()
        try connect(app)

        app.buttons["MobileTerminalDropdown"].tap()
        let tuiTerminal = app.buttons["MobileTerminalMenuItem-terminal-tui"]
        XCTAssertTrue(tuiTerminal.waitForExistence(timeout: 4))
        tuiTerminal.tap()

        XCTAssertTrue(app.staticTexts["LAZYGIT"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["files branches log"].exists)
        XCTAssertTrue(app.staticTexts["q quit"].exists)
    }

    @MainActor
    func testTerminalInputBarSendsPreviewText() throws {
        let app = launchApp()
        try connect(app)

        let field = app.textFields["MobileTerminalInputField"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("pwd")

        let sendButton = app.buttons["MobileTerminalSendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 4))
        sendButton.tap()

        XCTAssertTrue(app.staticTexts["> pwd"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testRemotePairingURLLoadsGhosttyScrollbackAndSendsInput() throws {
        let remote = try MobileSyncUITestServer(state: .singleWorkspace())
        defer { remote.stop() }
        let app = launchApp()

        try connect(app, pairingCode: remote.pairingURL)
        try openWorkspaceIfNeeded(app, workspaceID: "workspace-remote", visibleText: "true ghostty ui snapshot")

        XCTAssertTrue(app.staticTexts["Test Mac"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["old ui output"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["true ghostty ui snapshot"].exists)

        let field = app.textFields["MobileTerminalInputField"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("echo remote")

        let sendButton = app.buttons["MobileTerminalSendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 4))
        sendButton.tap()

        XCTAssertTrue(remote.waitForInput("echo remote\r", timeout: 4))
        XCTAssertTrue(app.staticTexts["ran echo remote"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testRemoteWorkspaceAndTerminalCreationRoundTripsThroughServer() throws {
        let remote = try MobileSyncUITestServer(state: .singleWorkspace())
        defer { remote.stop() }
        let app = launchApp()

        try connect(app, pairingCode: remote.pairingURL)
        try openWorkspaceIfNeeded(app, workspaceID: "workspace-remote", visibleText: "true ghostty ui snapshot")

        let newWorkspaceButton = app.buttons.matching(identifier: "MobileNewWorkspaceButton").firstMatch
        XCTAssertTrue(newWorkspaceButton.waitForExistence(timeout: 4))
        newWorkspaceButton.tap()

        try openWorkspaceIfNeeded(app, workspaceID: "workspace-created-1", visibleText: "created workspace snapshot")
        XCTAssertTrue(app.staticTexts["Created Workspace"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["created workspace snapshot"].exists)

        app.buttons["MobileTerminalDropdown"].tap()
        let newTerminal = app.buttons["MobileNewTerminalMenuItem"]
        XCTAssertTrue(newTerminal.waitForExistence(timeout: 4))
        newTerminal.tap()

        XCTAssertTrue(app.staticTexts["Created Terminal 1"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["created terminal snapshot"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testRemoteTerminalDropdownSwitchesFetchedSnapshots() throws {
        let remote = try MobileSyncUITestServer(state: .workspaceWithTwoTerminals())
        defer { remote.stop() }
        let app = launchApp()

        try connect(app, pairingCode: remote.pairingURL)
        try openWorkspaceIfNeeded(app, workspaceID: "workspace-remote", visibleText: "first terminal snapshot")

        app.buttons["MobileTerminalDropdown"].tap()
        let secondTerminal = app.buttons["MobileTerminalMenuItem-terminal-second"]
        XCTAssertTrue(secondTerminal.waitForExistence(timeout: 4))
        secondTerminal.tap()

        XCTAssertTrue(app.staticTexts["second terminal snapshot"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["first terminal snapshot"].exists)
    }

    @MainActor
    func testIPadShowsWorkspaceListAndTerminalTogether() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad-only split view check")
        }

        let app = launchApp()
        try connect(app)

        XCTAssertTrue(app.descendants(matching: .any)["MobileWorkspaceList"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["cmux-macbook"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Mobile Sync: enabled"].exists)
    }

    @MainActor
    func testIPadRemotePairingShowsListAndSnapshotTogether() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad-only split view check")
        }

        let remote = try MobileSyncUITestServer(state: .singleWorkspace())
        defer { remote.stop() }
        let app = launchApp()

        try connect(app, pairingCode: remote.pairingURL)

        XCTAssertTrue(app.descendants(matching: .any)["MobileWorkspaceList"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Test Mac"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["true ghostty ui snapshot"].exists)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func connect(_ app: XCUIApplication) throws {
        try connect(app, pairingCode: "debug")
        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.staticTexts["Mobile Sync: enabled"].waitForExistence(timeout: 4))
    }

    @MainActor
    private func connect(_ app: XCUIApplication, pairingCode: String) throws {
        XCTAssertTrue(app.buttons["MobileSignInButton"].waitForExistence(timeout: 8))
        app.buttons["MobileSignInButton"].tap()

        let field = app.textFields["MobilePairingCodeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText(pairingCode)
        app.buttons["MobileConnectButton"].tap()
    }

    @MainActor
    private func openSelectedWorkspaceIfNeeded(_ app: XCUIApplication) throws {
        if app.staticTexts["Mobile Sync: enabled"].waitForExistence(timeout: 1) {
            return
        }

        let row = app.otherElements["MobileWorkspaceRow-workspace-main"]
        if row.waitForExistence(timeout: 2) {
            row.tap()
            return
        }

        let fallback = app.staticTexts["cmux"]
        if fallback.waitForExistence(timeout: 2) {
            fallback.tap()
            return
        }

        XCTFail("Could not open the selected workspace")
    }

    @MainActor
    private func openWorkspaceIfNeeded(
        _ app: XCUIApplication,
        workspaceID: String,
        visibleText: String
    ) throws {
        if app.staticTexts[visibleText].waitForExistence(timeout: 4) {
            return
        }

        let row = app.otherElements["MobileWorkspaceRow-\(workspaceID)"]
        if row.waitForExistence(timeout: 4) {
            row.tap()
            XCTAssertTrue(app.staticTexts[visibleText].waitForExistence(timeout: 4))
            return
        }

        XCTFail("Could not open workspace \(workspaceID)")
    }
}

private final class MobileSyncUITestServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.cmux.mobile-sync.ui-tests.server")
    private let listener: NWListener
    private let state: MobileSyncUITestServerState
    private var connections: [MobileSyncUITestConnection] = []

    private(set) var port: Int = 0
    var pairingURL: String {
        Self.pairingURL(port: port)
    }

    init(state: MobileSyncUITestServerState) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        let resolvedPort = LockedUITestValue<Int?>(nil)
        let failure = LockedUITestValue<Error?>(nil)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                resolvedPort.set(listener.port.map { Int($0.rawValue) })
                ready.signal()
            case .failed(let error):
                failure.set(error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success,
              failure.value == nil,
              let port = resolvedPort.value else {
            listener.cancel()
            throw NSError(domain: "MobileSyncUITestServer", code: 1)
        }
        self.port = port
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.stop() }
        connections.removeAll()
    }

    func waitForInput(_ input: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.receivedInputs.contains(input) {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return state.receivedInputs.contains(input)
    }

    private func accept(_ connection: NWConnection) {
        let session = MobileSyncUITestConnection(connection: connection, state: state)
        connections.append(session)
        session.start(on: queue)
    }

    private static func pairingURL(port: Int) -> String {
        let payload: [String: Any] = [
            "version": 1,
            "mac_device_id": "ui-test-mac",
            "mac_display_name": "Test Mac",
            "host": "127.0.0.1",
            "port": port,
            "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)),
            "transport": "debug_loopback",
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cmux-ios://pair?v=1&payload=\(encoded)"
    }
}

private final class MobileSyncUITestConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let state: MobileSyncUITestServerState
    private var buffer = Data()

    init(connection: NWConnection, state: MobileSyncUITestServerState) {
        self.connection = connection
        self.state = state
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    func stop() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                processFrames()
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            receive()
        }
    }

    private func processFrames() {
        do {
            let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            for frame in frames {
                try respond(to: frame)
            }
        } catch {
            connection.cancel()
        }
    }

    private func respond(to frame: Data) throws {
        guard let request = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return
        }
        let result = state.handle(request)
        let envelope: [String: Any]
        if let error = result["error"] as? [String: Any] {
            envelope = [
                "id": request["id"] ?? NSNull(),
                "ok": false,
                "error": error,
            ]
        } else {
            envelope = [
                "id": request["id"] ?? NSNull(),
                "ok": true,
                "result": result,
            ]
        }
        let payload = try JSONSerialization.data(withJSONObject: envelope)
        let responseFrame = MobileSyncFrameCodec.encodeFrame(payload)
        connection.send(content: responseFrame, completion: .contentProcessed { _ in })
    }
}

private final class MobileSyncUITestServerState: @unchecked Sendable {
    struct Workspace {
        var id: String
        var title: String
        var isSelected: Bool
        var terminals: [Terminal]
    }

    struct Terminal {
        var id: String
        var title: String
        var isFocused: Bool
        var scrollbackLines: [String]
        var visibleLines: [String]
        var streamOffset: UInt64
    }

    private let lock = NSLock()
    private var workspaces: [Workspace]
    private var createdWorkspaceCount = 0
    private var createdTerminalCount = 0
    private var inputs: [String] = []

    var receivedInputs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return inputs
    }

    init(workspaces: [Workspace]) {
        self.workspaces = workspaces
    }

    static func singleWorkspace() -> MobileSyncUITestServerState {
        MobileSyncUITestServerState(
            workspaces: [
                Workspace(
                    id: "workspace-remote",
                    title: "Remote Workspace",
                    isSelected: true,
                    terminals: [
                        Terminal(
                            id: "terminal-remote",
                            title: "Remote Terminal",
                            isFocused: true,
                            scrollbackLines: ["old ui output"],
                            visibleLines: [
                                "$ cmux ios",
                                "remote workspace",
                                "true ghostty ui snapshot",
                                "ready",
                            ],
                            streamOffset: 10
                        ),
                    ]
                ),
            ]
        )
    }

    static func workspaceWithTwoTerminals() -> MobileSyncUITestServerState {
        MobileSyncUITestServerState(
            workspaces: [
                Workspace(
                    id: "workspace-remote",
                    title: "Remote Workspace",
                    isSelected: true,
                    terminals: [
                        Terminal(
                            id: "terminal-first",
                            title: "First Terminal",
                            isFocused: true,
                            scrollbackLines: [],
                            visibleLines: ["first terminal snapshot"],
                            streamOffset: 20
                        ),
                        Terminal(
                            id: "terminal-second",
                            title: "Second Terminal",
                            isFocused: false,
                            scrollbackLines: [],
                            visibleLines: ["second terminal snapshot"],
                            streamOffset: 21
                        ),
                    ]
                ),
            ]
        )
    }

    func handle(_ request: [String: Any]) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        switch request["method"] as? String {
        case "workspace.list":
            return workspaceListPayload()
        case "workspace.create":
            return createWorkspacePayload()
        case "terminal.create":
            return createTerminalPayload(request)
        case "terminal.snapshot":
            return terminalSnapshotPayload(request)
        case "terminal.input":
            return terminalInputPayload(request)
        default:
            return [
                "error": [
                    "code": "unknown_method",
                    "message": "Unknown UI test method",
                ],
            ]
        }
    }

    private func workspaceListPayload() -> [String: Any] {
        [
            "workspaces": workspaces.map(workspacePayload),
            "workspace_count": workspaces.count,
            "terminal_count": workspaces.reduce(0) { $0 + $1.terminals.count },
        ]
    }

    private func createWorkspacePayload() -> [String: Any] {
        createdWorkspaceCount += 1
        for index in workspaces.indices {
            workspaces[index].isSelected = false
            for terminalIndex in workspaces[index].terminals.indices {
                workspaces[index].terminals[terminalIndex].isFocused = false
            }
        }
        let workspace = Workspace(
            id: "workspace-created-\(createdWorkspaceCount)",
            title: "Created Workspace",
            isSelected: true,
            terminals: [
                Terminal(
                    id: "terminal-created-workspace-\(createdWorkspaceCount)",
                    title: "Created Workspace Terminal",
                    isFocused: true,
                    scrollbackLines: [],
                    visibleLines: ["created workspace snapshot"],
                    streamOffset: UInt64(100 + createdWorkspaceCount)
                ),
            ]
        )
        workspaces.append(workspace)
        var payload = workspaceListPayload()
        payload["created_workspace_id"] = workspace.id
        payload["created_terminal_id"] = workspace.terminals.first?.id ?? NSNull()
        return payload
    }

    private func createTerminalPayload(_ request: [String: Any]) -> [String: Any] {
        guard let workspaceIndex = workspaceIndex(from: request) else {
            return [
                "error": [
                    "code": "not_found",
                    "message": "Workspace not found",
                ],
            ]
        }
        createdTerminalCount += 1
        for terminalIndex in workspaces[workspaceIndex].terminals.indices {
            workspaces[workspaceIndex].terminals[terminalIndex].isFocused = false
        }
        let terminal = Terminal(
            id: "terminal-created-\(createdTerminalCount)",
            title: "Created Terminal \(createdTerminalCount)",
            isFocused: true,
            scrollbackLines: [],
            visibleLines: ["created terminal snapshot"],
            streamOffset: UInt64(200 + createdTerminalCount)
        )
        workspaces[workspaceIndex].terminals.append(terminal)
        var payload = workspaceListPayload()
        payload["created_workspace_id"] = workspaces[workspaceIndex].id
        payload["created_terminal_id"] = terminal.id
        return payload
    }

    private func terminalSnapshotPayload(_ request: [String: Any]) -> [String: Any] {
        guard let terminal = terminal(from: request) else {
            return [
                "error": [
                    "code": "not_found",
                    "message": "Terminal not found",
                ],
            ]
        }
        return [
            "snapshot": snapshotPayload(for: terminal),
            "surface_id": terminal.id,
        ]
    }

    private func terminalInputPayload(_ request: [String: Any]) -> [String: Any] {
        guard let params = request["params"] as? [String: Any],
              let text = params["text"] as? String else {
            return [
                "error": [
                    "code": "invalid_params",
                    "message": "Missing terminal input",
                ],
            ]
        }
        inputs.append(text)
        if let workspaceIndex = workspaceIndex(from: request),
           let terminalIndex = terminalIndex(from: request, workspaceIndex: workspaceIndex) {
            workspaces[workspaceIndex].terminals[terminalIndex].visibleLines = [
                "$ echo remote",
                "ran echo remote",
                "ready",
            ]
            workspaces[workspaceIndex].terminals[terminalIndex].streamOffset += 1
        }
        return [
            "accepted": true,
            "surface_id": (params["surface_id"] as? String) ?? NSNull(),
        ]
    }

    private func workspacePayload(_ workspace: Workspace) -> [String: Any] {
        [
            "id": workspace.id,
            "title": workspace.title,
            "currentDirectory": "/tmp/\(workspace.id)",
            "isSelected": workspace.isSelected,
            "terminals": workspace.terminals.map(terminalListPayload),
        ]
    }

    private func terminalListPayload(_ terminal: Terminal) -> [String: Any] {
        [
            "id": terminal.id,
            "title": terminal.title,
            "currentDirectory": "/tmp",
            "isFocused": terminal.isFocused,
        ]
    }

    private func workspaceIndex(from request: [String: Any]) -> Int? {
        let params = request["params"] as? [String: Any]
        let workspaceID = params?["workspace_id"] as? String
        return workspaces.firstIndex { $0.id == workspaceID || ($0.isSelected && workspaceID == nil) }
    }

    private func terminalIndex(from request: [String: Any], workspaceIndex: Int) -> Int? {
        let params = request["params"] as? [String: Any]
        let terminalID = params?["surface_id"] as? String ?? params?["terminal_id"] as? String
        return workspaces[workspaceIndex].terminals.firstIndex {
            $0.id == terminalID || ($0.isFocused && terminalID == nil)
        }
    }

    private func terminal(from request: [String: Any]) -> Terminal? {
        guard let workspaceIndex = workspaceIndex(from: request),
              let terminalIndex = terminalIndex(from: request, workspaceIndex: workspaceIndex) else {
            return nil
        }
        return workspaces[workspaceIndex].terminals[terminalIndex]
    }

    private func snapshotPayload(for terminal: Terminal) -> [String: Any] {
        let columns = 48
        let rows = 6
        return [
            "schemaVersion": 1,
            "terminalID": terminal.id,
            "gridSize": [
                "columns": columns,
                "rows": rows,
            ],
            "activeScreen": "primary",
            "scrollbackRows": terminal.scrollbackLines.map { rowPayload(line: $0, columns: columns) },
            "visibleRows": paddedRows(lines: terminal.visibleLines, columns: columns, rows: rows),
            "cursor": [
                "column": 0,
                "row": 0,
                "isVisible": true,
                "style": "block",
            ],
            "modes": [
                "bracketedPaste": false,
                "applicationCursorKeys": false,
                "applicationKeypad": false,
                "mouseTracking": false,
                "cursorVisible": true,
            ],
            "streamOffset": terminal.streamOffset,
            "generatedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0)),
        ]
    }

    private func paddedRows(lines: [String], columns: Int, rows: Int) -> [[String: Any]] {
        var padded = lines.prefix(rows).map { rowPayload(line: $0, columns: columns) }
        while padded.count < rows {
            padded.append(rowPayload(line: "", columns: columns))
        }
        return padded
    }

    private func rowPayload(line: String, columns: Int) -> [String: Any] {
        var cells = line.prefix(columns).map { character in
            cellPayload(text: String(character))
        }
        while cells.count < columns {
            cells.append(cellPayload(text: ""))
        }
        return [
            "cells": cells,
            "isWrapped": false,
        ]
    }

    private func cellPayload(text: String) -> [String: Any] {
        [
            "text": text,
            "width": "narrow",
            "style": [
                "bold": false,
                "italic": false,
                "dim": false,
                "inverse": false,
                "underline": "none",
            ],
        ]
    }
}

private enum MobileSyncFrameCodec {
    static let headerByteCount = 4

    static func encodeFrame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: headerByteCount)
        frame.append(payload)
        return frame
    }

    static func decodeFrames(from buffer: inout Data) throws -> [Data] {
        var frames: [Data] = []
        while buffer.count >= headerByteCount {
            let length = buffer.prefix(headerByteCount).reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
            let payloadLength = Int(length)
            guard buffer.count >= headerByteCount + payloadLength else {
                break
            }
            let payloadStart = headerByteCount
            let payloadEnd = payloadStart + payloadLength
            frames.append(buffer.subdata(in: payloadStart..<payloadEnd))
            buffer.removeSubrange(0..<payloadEnd)
        }
        return frames
    }
}

private final class LockedUITestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
