import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobilePairedMac
import CmuxMobileRPC
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI
import CmuxMobileShellModel
import CmuxMobileWorkspace
import Foundation
import StackAuth
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import cmuxFeature


// MARK: - Attach ticket auth + workspace list routing
@MainActor
@Test func unsupportedAttachTicketClearsPreviousRemoteClient() async throws {
    let supportedRoute = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let supportedTicket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [supportedRoute],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: supportedTicket).absoluteString)
    #expect(store.phase == .workspaces)

    let unsupportedRoute = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(id: "iroh-peer", relayHint: nil, directAddrs: [], relayURL: nil)
    )
    let unsupportedTicket = try CmxAttachTicket(
        workspaceID: "iroh-workspace",
        terminalID: "iroh-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [unsupportedRoute],
        expiresAt: Date().addingTimeInterval(60)
    )
    await store.connectPairingURL(try attachURL(for: unsupportedTicket).absoluteString)

    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError == "This pairing code is not supported.")

    store.terminalInputText = "echo should-not-hit-old-host"
    await store.submitTerminalInput()

    let requests = try await responses.sentRequests()
    #expect(requests.contains { $0.method == "workspace.list" })
    #expect(!requests.contains { $0.method == "terminal.input" })
}

@MainActor
@Test func manualFallbackTicketListsWorkspacesWithoutSyntheticWorkspaceFilter() async throws {
    let responses = ScriptedTransportResponses([
        try rpcErrorFrame(message: "ticket unavailable"),
        try rpcWorkspaceListFrame(workspaceID: "local-workspace", title: "Local Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)

    let requests = try await responses.sentRequests()
    let workspaceList = try #require(requests.first { $0.method == "workspace.list" })
    #expect(workspaceList.workspaceID == nil)
    #expect(store.phase == .workspaces)
}

@MainActor
@Test func uuidAttachTicketListsAllWorkspacesFirstWithAttachToken() async throws {
    let workspaceID = UUID().uuidString
    let route = try hostPortRoute(kind: .tailscale, host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: workspaceID, title: "Scoped Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let requests = try await responses.sentRequests()
    let workspaceList = try #require(requests.first { $0.method == "workspace.list" })
    #expect(workspaceList.workspaceID == nil)
    #expect(workspaceList.attachToken == "ticket-secret")
    #expect(workspaceList.stackAccessToken == "test-stack-token")
    #expect(store.selectedWorkspace?.id.rawValue == workspaceID)
}

@MainActor
@Test func signedInAttachTicketConnectsWithFullWorkspaceListFirst() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let docsWorkspaceID = UUID().uuidString
    let docsTerminalID = UUID().uuidString
    let route = try hostPortRoute(kind: .tailscale, host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": workspaceID,
                        "title": "cmux",
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": terminalID,
                                "title": "Build",
                                "current_directory": "/Users/test/project",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                    [
                        "id": docsWorkspaceID,
                        "title": "Docs",
                        "current_directory": "/Users/test/docs",
                        "is_selected": false,
                        "terminals": [
                            [
                                "id": docsTerminalID,
                                "title": "Notes",
                                "current_directory": "/Users/test/docs",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                ],
            ]
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let workspaceLists = try await waitForWorkspaceListRequestCount(1, responses: responses)
    #expect(workspaceLists[0].workspaceID == nil)
    #expect(workspaceLists[0].terminalID == nil)
    #expect(workspaceLists.allSatisfy { $0.attachToken == "ticket-secret" })
    #expect(workspaceLists.allSatisfy { $0.stackAccessToken == "test-stack-token" })
    let workspaceIDs = try await waitForWorkspaceIDs(in: store, matching: [workspaceID, docsWorkspaceID])
    #expect(workspaceIDs == [workspaceID, docsWorkspaceID])
    #expect(store.selectedWorkspace?.id.rawValue == workspaceID)
}

@MainActor
@Test func signedInLoopbackAttachTicketConnectsWithFullWorkspaceListFirst() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let secondWorkspaceID = UUID().uuidString
    let secondTerminalID = UUID().uuidString
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": workspaceID,
                        "title": "Main",
                        "current_directory": "/Users/test/project",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": terminalID,
                                "title": "Build",
                                "current_directory": "/Users/test/project",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                    [
                        "id": secondWorkspaceID,
                        "title": "Second",
                        "current_directory": "/Users/test/second",
                        "is_selected": false,
                        "terminals": [
                            [
                                "id": secondTerminalID,
                                "title": "Shell",
                                "current_directory": "/Users/test/second",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                ],
            ]
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let workspaceLists = try await waitForWorkspaceListRequestCount(1, responses: responses)
    #expect(workspaceLists[0].workspaceID == nil)
    #expect(workspaceLists[0].terminalID == nil)
    #expect(workspaceLists.allSatisfy { $0.attachToken == "ticket-secret" })
    #expect(workspaceLists.allSatisfy { $0.stackAccessToken == "test-stack-token" })
    let workspaceIDs = try await waitForWorkspaceIDs(in: store, matching: [workspaceID, secondWorkspaceID])
    #expect(workspaceIDs == [workspaceID, secondWorkspaceID])
}

@MainActor
@Test func signedInAttachTicketFallsBackToScopedWorkspaceWhenFullListFails() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let route = try hostPortRoute(kind: .tailscale, host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcErrorFrame(message: "Full list not supported"),
        try rpcWorkspaceListFrame(workspaceID: workspaceID, title: "Scoped Workspace", terminalID: terminalID),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let workspaceLists = try await waitForWorkspaceListRequestCount(2, responses: responses)
    #expect(workspaceLists[0].workspaceID == nil)
    #expect(workspaceLists[0].terminalID == nil)
    #expect(workspaceLists[1].workspaceID == workspaceID)
    #expect(workspaceLists[1].terminalID == terminalID)
    #expect(workspaceLists.allSatisfy { $0.attachToken == "ticket-secret" })
    #expect(store.workspaces.map(\.id.rawValue) == [workspaceID])
}

@MainActor
@Test func terminalScopedAttachTicketWithAttachTokenListsAllWorkspacesFirst() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: workspaceID, title: "Scoped Workspace", terminalID: terminalID),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let requests = try await responses.sentRequests()
    let workspaceList = try #require(requests.first { $0.method == "workspace.list" })
    #expect(workspaceList.workspaceID == nil)
    #expect(workspaceList.terminalID == nil)
    #expect(workspaceList.attachToken == "ticket-secret")
    #expect(workspaceList.stackAccessToken == "test-stack-token")
    #expect(store.selectedWorkspace?.terminals.first?.id.rawValue == terminalID)
}

@MainActor
@Test func attachTicketFallsBackToNextRouteWhenPreferredRouteFails() async throws {
    let workspaceID = UUID().uuidString
    let preferredRoute = try CmxAttachRoute(
        id: "magicdns",
        kind: .tailscale,
        endpoint: .hostPort(host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort),
        priority: 10
    )
    let fallbackRoute = try CmxAttachRoute(
        id: "numeric",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort),
        priority: 20
    )
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [fallbackRoute, preferredRoute],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: workspaceID, title: "Fallback Workspace"),
    ])
    let attempts = RouteAttemptRecorder()
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: FailingRouteTransportFactory(
            failingRouteID: preferredRoute.id,
            responses: responses,
            attempts: attempts
        )
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    #expect(await attempts.routeIDs() == [preferredRoute.id, preferredRoute.id, fallbackRoute.id])
    #expect(store.connectionState == .connected)
    #expect(store.activeRoute?.id == fallbackRoute.id)
    #expect(store.selectedWorkspace?.id.rawValue == workspaceID)
}

@MainActor
@Test func failedAttachTicketDoesNotPersistActivePairedMac() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pairedMacStore = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("paired-macs.sqlite3"))
    let route = try hostPortRoute(
        kind: .tailscale,
        host: "100.71.210.41",
        port: CmxMobileDefaults.defaultHostPort
    )
    let ticket = try CmxAttachTicket(
        workspaceID: UUID().uuidString,
        terminalID: nil,
        macDeviceID: "offline-mac",
        macDisplayName: "Offline Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([])
    let attempts = RouteAttemptRecorder()
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: FailingRouteTransportFactory(
            failingRouteID: route.id,
            responses: responses,
            attempts: attempts
        )
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        pairedMacStore: pairedMacStore
    )

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    #expect(store.connectionState == .disconnected)
    #expect(try await pairedMacStore.activeMac() == nil)
    #expect(try await pairedMacStore.loadAll().isEmpty)
}

@MainActor
@Test func expiredNetworkAttachTicketFromPairLinkDoesNotFallbackToStackAuth() async throws {
    let ticketExpiresAt = Date().addingTimeInterval(60)
    let route = try hostPortRoute(kind: .tailscale, host: "attacker.example", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: "expired-workspace",
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: ticketExpiresAt,
        authToken: "expired-ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "expired-workspace", title: "Expired Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-after-ticket-expiry",
        now: { ticketExpiresAt.addingTimeInterval(1) }
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    #expect(try await responses.sentRequests().isEmpty)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError != nil)
}

@MainActor
@Test func pairLinkWithoutAttachTokenRejectsArbitraryHostBeforeSendingAuth() async throws {
    let route = try hostPortRoute(kind: .tailscale, host: "attacker.example", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: UUID().uuidString,
        terminalID: nil,
        macDeviceID: "untrusted-mac",
        macDisplayName: "Untrusted Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: ticket.workspaceID, title: "Untrusted Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "do-not-send"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let requests = try await responses.sentRequests()
    #expect(requests.isEmpty)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError != nil)
}

