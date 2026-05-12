import Testing
import CMUXMobileSyncCore
import Foundation
import Network
@testable import cmuxMobileFeature

@MainActor
@Test func startsAtSignInWithoutConnection() {
    let store = CMUXMobileShellStore.preview()

    #expect(store.phase == .signIn)
    #expect(store.isSignedIn == false)
    #expect(store.connectionState == .disconnected)
    #expect(store.selectedWorkspace?.name == "cmux")
    #expect(store.selectedTerminalID?.rawValue == "terminal-build")
}

@MainActor
@Test func signInMovesToPairingUntilCodeConnects() {
    let store = CMUXMobileShellStore.preview()

    store.signIn()
    #expect(store.phase == .pairing)

    store.connectPreviewHost()
    #expect(store.phase == .pairing)

    store.pairingCode = "debug"
    store.connectPreviewHost()
    #expect(store.phase == .workspaces)
    #expect(store.connectedHostName == "cmux-macbook")
}

@MainActor
@Test func createWorkspaceSelectsNewWorkspaceAndTerminal() {
    let store = CMUXMobileShellStore.preview()
    store.signIn()
    store.pairingCode = "debug"
    store.connectPreviewHost()

    store.createWorkspace()

    #expect(store.workspaces.count == 3)
    #expect(store.selectedWorkspace?.id.rawValue == "workspace-3")
    #expect(store.selectedTerminalID?.rawValue == "workspace-3-terminal-1")
}

@MainActor
@Test func createTerminalAddsTerminalToSelectedWorkspace() {
    let store = CMUXMobileShellStore.preview()
    store.signIn()
    store.pairingCode = "debug"
    store.connectPreviewHost()

    store.createTerminal()

    #expect(store.selectedWorkspace?.id.rawValue == "workspace-main")
    #expect(store.selectedWorkspace?.terminals.count == 4)
    #expect(store.selectedTerminalID?.rawValue == "workspace-main-terminal-4")
}

@MainActor
@Test func selectingWorkspaceReconcilesTerminalSelection() {
    let store = CMUXMobileShellStore.preview()
    store.signIn()
    store.pairingCode = "debug"
    store.connectPreviewHost()
    store.selectTerminal("terminal-agent")

    store.selectedWorkspaceID = "workspace-docs"

    #expect(store.selectedWorkspace?.id.rawValue == "workspace-docs")
    #expect(store.selectedTerminalID?.rawValue == "terminal-notes")
}

@MainActor
@Test func previewHostIncludesAlternateScreenSnapshotTerminal() {
    let store = CMUXMobileShellStore.preview()
    let workspace = store.workspaces.first { $0.id.rawValue == "workspace-main" }
    let terminal = workspace?.terminals.first { $0.id.rawValue == "terminal-tui" }

    #expect(terminal?.snapshot.activeScreen == .alternate)
    #expect(terminal?.snapshot.modes.mouseTracking == true)
    #expect(terminal?.snapshot.modes.bracketedPaste == true)
    #expect(terminal?.lines.first == "LAZYGIT")
    #expect(terminal?.snapshot.streamOffset == 128)
}

@MainActor
@Test func pairingURLLoadsRemoteWorkspacesAndSelectedTerminalSnapshot() async throws {
    let snapshot = try MobileTerminalGhosttySnapshot.fixture(
        terminalID: "terminal-live",
        columns: 40,
        rows: 4,
        scrollbackLines: ["old output"],
        visibleLines: [
            "$ cmux ios",
            "remote workspace",
            "true ghostty snapshot",
            "ready",
        ],
        streamOffset: 42
    )
    let receivedInput = LockedTestValue<String?>(nil)
    let snapshotObject = try JSONSerialization.jsonObject(
        with: snapshot.encodedValidatedJSON()
    ) as! [String: Any]
    let server = try MobileSyncLoopbackTestServer { request in
        switch request["method"] as? String {
        case "workspace.list":
            return [
                "workspaces": [
                    [
                        "id": "workspace-live",
                        "title": "Live Workspace",
                        "currentDirectory": "/tmp/live",
                        "isSelected": true,
                        "terminals": [
                            [
                                "id": "terminal-live",
                                "title": "Live Terminal",
                                "currentDirectory": "/tmp/live",
                                "isFocused": true,
                            ],
                        ],
                    ],
                ],
                "workspace_count": 1,
                "terminal_count": 1,
            ]
        case "terminal.snapshot":
            return [
                "snapshot": snapshotObject,
                "surface_id": "terminal-live",
                "workspace_id": "workspace-live",
            ]
        case "terminal.input":
            let params = request["params"] as? [String: Any]
            receivedInput.set(params?["text"] as? String)
            return [
                "accepted": true,
                "surface_id": "terminal-live",
                "workspace_id": "workspace-live",
            ]
        default:
            return [
                "error": [
                    "code": "unknown_method",
                    "message": "Unknown test method",
                ],
            ]
        }
    }
    defer { server.stop() }
    let payload = try MobileSyncPairingPayload(
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        host: "127.0.0.1",
        port: server.port,
        expiresAt: Date().addingTimeInterval(60),
        transport: .debugLoopback
    )

    let store = CMUXMobileShellStore.preview()
    store.signIn()
    await store.connectPairingURL(try payload.encodedURL().absoluteString)

    #expect(store.phase == .workspaces)
    #expect(store.connectedHostName == "Test Mac")
    #expect(store.workspaces.map(\.name) == ["Live Workspace"])
    #expect(store.selectedTerminalID?.rawValue == "terminal-live")
    #expect(store.selectedWorkspace?.terminals.first?.lines.contains("true ghostty snapshot") == true)
    #expect(store.selectedWorkspace?.terminals.first?.snapshot.scrollbackRows.first?.trimmedPlainText == "old output")
    #expect(store.selectedWorkspace?.terminals.first?.snapshot.streamOffset == 42)

    store.terminalInputText = "echo hi"
    await store.submitTerminalInput()

    #expect(receivedInput.value == "echo hi\r")
    #expect(store.terminalInputText.isEmpty)
}

private final class MobileSyncLoopbackTestServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.cmux.mobile-sync.tests.server")
    private let listener: NWListener
    private let handler: ([String: Any]) -> [String: Any]
    private var connections: [MobileSyncLoopbackTestConnection] = []

    private(set) var port: Int = 0

    init(handler: @escaping ([String: Any]) -> [String: Any]) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let createdListener = try NWListener(using: parameters)
        listener = createdListener

        let ready = DispatchSemaphore(value: 0)
        let failure = LockedTestValue<Error?>(nil)
        let resolvedPort = LockedTestValue<Int?>(nil)
        createdListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                resolvedPort.set(createdListener.port.map { Int($0.rawValue) })
                ready.signal()
            case .failed(let error):
                failure.set(error)
                ready.signal()
            default:
                break
            }
        }
        createdListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        createdListener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw MobileShellConnectionError.connectionClosed
        }
        if let error = failure.value {
            listener.cancel()
            throw error
        }
        guard let port = resolvedPort.value else {
            listener.cancel()
            throw MobileShellConnectionError.connectionClosed
        }
        self.port = port
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.stop() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let session = MobileSyncLoopbackTestConnection(connection: connection, handler: handler)
        connections.append(session)
        session.start(on: queue)
    }
}

private final class MobileSyncLoopbackTestConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: ([String: Any]) -> [String: Any]
    private var buffer = Data()

    init(connection: NWConnection, handler: @escaping ([String: Any]) -> [String: Any]) {
        self.connection = connection
        self.handler = handler
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
                do {
                    let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
                    for frame in frames {
                        try self.respond(to: frame)
                    }
                } catch {
                    connection.cancel()
                    return
                }
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            receive()
        }
    }

    private func respond(to frame: Data) throws {
        guard let request = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            return
        }
        let envelope: [String: Any] = [
            "id": request["id"] ?? NSNull(),
            "ok": true,
            "result": handler(request),
        ]
        let payload = try JSONSerialization.data(withJSONObject: envelope)
        let responseFrame = try MobileSyncFrameCodec.encodeFrame(payload)
        connection.send(content: responseFrame, completion: .contentProcessed { _ in })
    }
}

private final class LockedTestValue<Value>: @unchecked Sendable {
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
