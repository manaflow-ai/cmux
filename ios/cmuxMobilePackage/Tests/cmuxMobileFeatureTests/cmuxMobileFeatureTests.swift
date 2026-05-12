import CMUXMobileCore
import Foundation
import Testing
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

@Test func authBuildPolicyCompilesDevShortcutOnlyForDebug() {
    #if CMUX_DEV_AUTH
    #expect(MobileAuthBuildPolicy.includesFortyTwoShortcut)
    #else
    #expect(!MobileAuthBuildPolicy.includesFortyTwoShortcut)
    #endif
}

@MainActor
@Test func rootAuthGateIgnoresLegacyShellSignInState() {
    let store = CMUXMobileShellStore.preview()

    store.signIn()

    #expect(store.isSignedIn)
    #expect(!MobileRootAuthGate.isAuthenticated(stackAuthenticated: false))
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
@Test func pairingURLUsesCMUXMobileCorePayloadWithoutConcreteTransport() async throws {
    let payload = try MobileSyncPairingPayload(
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        host: "127.0.0.1",
        port: 49831,
        expiresAt: Date().addingTimeInterval(60),
        transport: .debugLoopback
    )
    let store = CMUXMobileShellStore.preview()

    store.signIn()
    await store.connectPairingURL(try payload.encodedURL().absoluteString)

    #expect(store.phase == .workspaces)
    #expect(store.connectedHostName == "Test Mac")
    #expect(store.activeTicket?.macDeviceID == "test-mac")
    #expect(store.activeRoute?.kind == .debugLoopback)
    #expect(store.selectedWorkspace?.id.rawValue == "workspace-main")
    #expect(store.selectedWorkspace?.terminals.first?.lines.contains("runtime: waiting for transport") == true)
}

@MainActor
@Test func wrappedAttachURLWhitespaceIsAccepted() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56577)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let url = try attachURL(for: ticket).absoluteString
    let wrappedURL = String(url.prefix(72)) + "\n  " + String(url.dropFirst(72))
    let store = CMUXMobileShellStore.preview()

    store.signIn()
    await store.connectPairingURL(String(wrappedURL))

    #expect(store.phase == .workspaces)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "Test Mac")
    #expect(store.activeRoute?.kind == .debugLoopback)
    #expect(store.selectedWorkspace?.id.rawValue == "live-workspace")
}

@MainActor
@Test func attachURLWithoutPathStillConnects() async throws {
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "devbox.local", port: 15432)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let url = try attachURL(for: ticket)
    let store = CMUXMobileShellStore.preview()

    #expect(url.host == "attach")
    #expect(url.path.isEmpty)

    store.signIn()
    await store.connectPairingURL(url.absoluteString)

    #expect(store.phase == .workspaces)
    #expect(store.connectionError == nil)
    #expect(store.activeTicket == ticket)
    #expect(store.activeRoute == route)
}

@MainActor
@Test func remoteWorkspaceListAcceptsMacSnakeCasePayload() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": "live-workspace",
                        "title": "Live Workspace",
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [],
                    ],
                ],
            ]
        ),
    ])
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    #expect(store.phase == .workspaces)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "Test Mac")
    #expect(store.selectedWorkspace?.id.rawValue == "live-workspace")
    #expect(store.selectedWorkspace?.name == "Live Workspace")
    #expect(store.selectedTerminalID == nil)
}

@MainActor
@Test func manualHostPairingUsesNetworkRouteForTailscaleAddress() async throws {
    let responses = ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": "live-workspace",
                        "title": "Live Workspace",
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [],
                    ],
                ],
            ]
        ),
    ])
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Work Mac", host: "100.71.210.41", port: 4865)

    let route = try #require(store.activeRoute)
    #expect(store.phase == .workspaces)
    #expect(store.connectedHostName == "Work Mac")
    #expect(route.kind == .tailscale)
    if case let .hostPort(host, port) = route.endpoint {
        #expect(host == "100.71.210.41")
        #expect(port == 4865)
    } else {
        Issue.record("manual Tailscale route should use host/port")
    }
}

@MainActor
@Test func manualHostPairingUsesHostPortRouteForLANAddressAndCustomPort() async throws {
    let responses = try scriptedWorkspaceListResponses(
        workspaceID: "lan-workspace",
        title: "LAN Workspace"
    )
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Studio LAN", host: " 192.168.1.77 ", port: 15432)

    let route = try #require(store.activeRoute)
    #expect(store.phase == .workspaces)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "Studio LAN")
    #expect(route.kind == .tailscale)
    if case let .hostPort(host, port) = route.endpoint {
        #expect(host == "192.168.1.77")
        #expect(port == 15432)
    } else {
        Issue.record("manual LAN route should use host/port")
    }
}

@MainActor
@Test func manualHostPairingUsesHostPortRouteForDNSNameAndCustomPort() async throws {
    let responses = try scriptedWorkspaceListResponses(
        workspaceID: "dns-workspace",
        title: "DNS Workspace"
    )
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "devbox.local", port: 61234)

    let route = try #require(store.activeRoute)
    #expect(store.phase == .workspaces)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "devbox.local")
    #expect(route.kind == .tailscale)
    if case let .hostPort(host, port) = route.endpoint {
        #expect(host == "devbox.local")
        #expect(port == 61234)
    } else {
        Issue.record("manual DNS route should use host/port")
    }
}

@MainActor
@Test func manualHostPairingUsesLoopbackRouteForLocalhost() async throws {
    let responses = ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": "local-workspace",
                        "title": "Local Workspace",
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [],
                    ],
                ],
            ]
        ),
    ])
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: 4865)

    let route = try #require(store.activeRoute)
    #expect(store.phase == .workspaces)
    #expect(store.connectedHostName == "127.0.0.1")
    #expect(route.kind == .debugLoopback)
    if case let .hostPort(host, port) = route.endpoint {
        #expect(host == "127.0.0.1")
        #expect(port == 4865)
    } else {
        Issue.record("manual loopback route should use host/port")
    }
}

@MainActor
@Test func manualHostPairingRejectsInvalidHost() async {
    let store = CMUXMobileShellStore.preview()

    store.signIn()
    await store.connectManualHost(name: "Bad Host", host: "dev box.local", port: 4865)

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.activeTicket == nil)
    #expect(store.activeRoute == nil)
    #expect(store.connectionError == "Enter a host or IP address, without spaces or URL paths.")
}

@MainActor
@Test func manualHostPairingRejectsInvalidPort() async {
    let store = CMUXMobileShellStore.preview()

    store.signIn()
    await store.connectManualHost(name: "Bad Port", host: "devbox.local", port: 70_000)

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.activeTicket == nil)
    #expect(store.activeRoute == nil)
    #expect(store.connectionError == "Enter a port from 1 to 65535.")
}

@MainActor
@Test func terminalSurfaceNotReadyReplacesPlaceholderWithoutPairingError() async throws {
    let responses = ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": "local-workspace",
                        "title": "Local Workspace",
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": "local-terminal",
                                "title": "Local Terminal",
                                "current_directory": "/Users/test/project",
                                "is_focused": true,
                            ],
                        ],
                    ],
                ],
            ]
        ),
        try rpcErrorFrame(message: "Terminal surface is not ready"),
    ])
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: 4865)

    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.terminals.first?.lines.first == "Terminal surface is still starting.")
}

@MainActor
@Test func workspaceListPrefersReadyTerminalBeforeSnapshotRefresh() async throws {
    let responses = ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": "local-workspace",
                        "title": "Local Workspace",
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": "stale-terminal",
                                "title": "Stale Terminal",
                                "current_directory": "/Users/test/project",
                                "is_ready": false,
                                "is_focused": true,
                            ],
                            [
                                "id": "ready-terminal",
                                "title": "Ready Terminal",
                                "current_directory": "/Users/test/project",
                                "is_ready": true,
                                "is_focused": false,
                            ],
                        ],
                    ],
                ],
            ]
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "local-workspace",
            terminalID: "ready-terminal",
            visibleLines: ["ready terminal"]
        ),
    ])
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: 4865)

    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.id.rawValue == "local-workspace")
    #expect(store.selectedTerminalID?.rawValue == "ready-terminal")
    #expect(store.selectedWorkspace?.terminals.first { $0.id.rawValue == "ready-terminal" }?.lines.first == "ready terminal")
}

@MainActor
@Test func notReadySelectedTerminalFallsBackToReadyTerminalInAnotherWorkspace() async throws {
    let responses = ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": "stale-workspace",
                        "title": "Stale Workspace",
                        "current_directory": "/Users/test/stale",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": "stale-terminal",
                                "title": "Stale Terminal",
                                "current_directory": "/Users/test/stale",
                                "is_ready": false,
                                "is_focused": true,
                            ],
                        ],
                    ],
                    [
                        "id": "ready-workspace",
                        "title": "Ready Workspace",
                        "current_directory": "/Users/test/ready",
                        "is_selected": false,
                        "terminals": [
                            [
                                "id": "ready-terminal",
                                "title": "Ready Terminal",
                                "current_directory": "/Users/test/ready",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                ],
            ]
        ),
        try rpcErrorFrame(message: "Terminal surface is not ready"),
        try rpcSnapshotResultFrame(
            workspaceID: "ready-workspace",
            terminalID: "ready-terminal",
            visibleLines: ["ready from another workspace"]
        ),
    ])
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: 4865)

    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.id.rawValue == "ready-workspace")
    #expect(store.selectedTerminalID?.rawValue == "ready-terminal")
    #expect(store.selectedWorkspace?.terminals.first?.lines.first == "ready from another workspace")
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

@Test func terminalRowProjectionPreservesTrailingBlankCursorCell() {
    let row = MobileTerminalGhosttyRow(
        cells: [
            MobileTerminalGhosttyCell(text: "$"),
            MobileTerminalGhosttyCell(text: " "),
            MobileTerminalGhosttyCell(text: ""),
            MobileTerminalGhosttyCell(text: ""),
            MobileTerminalGhosttyCell(text: ""),
        ]
    )

    let trimmed = TerminalRowCellProjection.cells(from: row, preservingCursorColumn: nil)
    let cursorPreserved = TerminalRowCellProjection.cells(from: row, preservingCursorColumn: 4)

    #expect(trimmed.count == 1)
    #expect(cursorPreserved.count == 5)
    #expect(cursorPreserved.last?.text == "")
}

private func attachURL(for ticket: CmxAttachTicket) throws -> URL {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = base64URLEncode(try encoder.encode(ticket))
    return try #require(URL(string: "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)"))
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func scriptedWorkspaceListResponses(
    workspaceID: String,
    title: String
) throws -> ScriptedTransportResponses {
    ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": workspaceID,
                        "title": title,
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [],
                    ],
                ],
            ]
        ),
    ])
}

private struct ScriptedTransportFactory: CmxByteTransportFactory {
    let responses: ScriptedTransportResponses

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        ScriptedTransport(responses: responses)
    }
}

private actor ScriptedTransportResponses {
    private var frames: [Data]

    init(_ frames: [Data]) {
        self.frames = frames
    }

    func next() -> Data? {
        guard !frames.isEmpty else {
            return nil
        }
        return frames.removeFirst()
    }
}

private actor ScriptedTransport: CmxByteTransport {
    private let responses: ScriptedTransportResponses

    init(responses: ScriptedTransportResponses) {
        self.responses = responses
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        await responses.next()
    }

    func send(_ data: Data) async throws {}

    func close() async {}
}

private func rpcResultFrame(result: [String: Any]) throws -> Data {
    let envelope: [String: Any] = [
        "id": UUID().uuidString,
        "ok": true,
        "result": result,
    ]
    let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
    return try MobileSyncFrameCodec.encodeFrame(envelopeData)
}

private func rpcErrorFrame(message: String) throws -> Data {
    let envelope: [String: Any] = [
        "id": UUID().uuidString,
        "ok": false,
        "error": [
            "message": message,
        ],
    ]
    let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
    return try MobileSyncFrameCodec.encodeFrame(envelopeData)
}

private func rpcSnapshotResultFrame(
    workspaceID: String,
    terminalID: String,
    visibleLines: [String]
) throws -> Data {
    let snapshot = try MobileTerminalGhosttySnapshot.fixture(
        terminalID: terminalID,
        visibleLines: visibleLines
    )
    let snapshotObject = try JSONSerialization.jsonObject(with: snapshot.encodedValidatedJSON())
    return try rpcResultFrame(
        result: [
            "workspace_id": workspaceID,
            "surface_id": terminalID,
            "snapshot": snapshotObject,
        ]
    )
}
