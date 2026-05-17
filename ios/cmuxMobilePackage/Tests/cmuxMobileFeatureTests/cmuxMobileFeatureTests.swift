import CMUXMobileCore
import Foundation
import SwiftUI
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

@Test func compactHeightUsesStackWorkspaceNavigation() {
    #expect(
        MobileWorkspaceShellLayoutPolicy.usesCompactStack(
            horizontalSizeClass: .regular,
            verticalSizeClass: .compact
        )
    )
    #expect(
        MobileWorkspaceShellLayoutPolicy.usesCompactStack(
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular
        )
    )
    #expect(
        !MobileWorkspaceShellLayoutPolicy.usesCompactStack(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular
        )
    )
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
    let runtime = testRuntime(
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
@Test func attachURLSelectsTicketWorkspaceOverPersistedMobileSelection() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "ticket-workspace",
        terminalID: "ticket-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    let responses = ScriptedTransportResponses([
        try rpcResultFrame(
            result: [
                "workspaces": [
                    [
                        "id": "workspace-main",
                        "title": "Persisted Selection",
                        "current_directory": "/Users/test/old",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": "terminal-build",
                                "title": "Old Terminal",
                                "current_directory": "/Users/test/old",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                    [
                        "id": "ticket-workspace",
                        "title": "Ticket Workspace",
                        "current_directory": "/Users/test/new",
                        "is_selected": false,
                        "terminals": [
                            [
                                "id": "ticket-terminal",
                                "title": "Ticket Terminal",
                                "current_directory": "/Users/test/new",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                        ],
                    ],
                ],
            ]
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "ticket-workspace",
            terminalID: "ticket-terminal",
            visibleLines: ["ticket workspace selected"]
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    #expect(store.phase == .workspaces)
    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.id.rawValue == "ticket-workspace")
    #expect(store.selectedTerminalID?.rawValue == "ticket-terminal")
    #expect(store.selectedWorkspace?.terminals.first?.lines.contains("ticket workspace selected") == true)
}

@MainActor
@Test func manualHostPairingUsesNetworkRouteForTailscaleMagicDNSHost() async throws {
    let attachRoute = try hostPortRoute(
        kind: .tailscale,
        host: "work-mac.tailnet.ts.net",
        port: CmxMobileDefaults.defaultHostPort
    )
    let responses = ScriptedTransportResponses([
        try rpcAttachTicketFrame(route: attachRoute, workspaceID: "live-workspace"),
        try rpcWorkspaceListFrame(workspaceID: "live-workspace", title: "Live Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Work Mac", host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)

    let route = try #require(store.activeRoute)
    #expect(store.phase == .workspaces)
    #expect(store.connectedHostName == "Work Mac")
    #expect(route.kind == .tailscale)
    if case let .hostPort(host, port) = route.endpoint {
        #expect(host == "work-mac.tailnet.ts.net")
        #expect(port == CmxMobileDefaults.defaultHostPort)
    } else {
        Issue.record("manual Tailscale route should use host/port")
    }
}

@MainActor
@Test func manualHostPairingUsesHostPortRouteForLANAddressAndCustomPort() async throws {
    let advertisedRoute = try hostPortRoute(kind: .tailscale, host: "work-mac.tailnet.ts.net", port: 15432, priority: 10)
    let responses = ScriptedTransportResponses([
        try rpcHostStatusFrame(routes: [
            try routePayload(kind: .tailscale, host: "work-mac.tailnet.ts.net", port: 15432, priority: 10),
        ]),
        try rpcAttachTicketFrame(route: advertisedRoute, workspaceID: "lan-workspace"),
        try rpcWorkspaceListFrame(workspaceID: "lan-workspace", title: "LAN Workspace"),
    ])
    let runtime = testRuntime(
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
        #expect(host == "work-mac.tailnet.ts.net")
        #expect(port == 15432)
    } else {
        Issue.record("manual LAN route should switch to the advertised Tailscale host/port")
    }
    let requests = try await responses.sentRequests()
    #expect(requests.first?.method == "mobile.host.status")
    #expect(requests.first?.hasAuth == false)
    #expect(requests.dropFirst().first?.method == "mobile.attach_ticket.create")
    #expect(requests.dropFirst(2).first?.method == "workspace.list")
}

@MainActor
@Test func manualHostPairingUsesHostPortRouteForDNSNameAndCustomPort() async throws {
    let advertisedRoute = try hostPortRoute(kind: .tailscale, host: "work-mac.tailnet.ts.net", port: 61234, priority: 10)
    let responses = ScriptedTransportResponses([
        try rpcHostStatusFrame(routes: [
            try routePayload(kind: .tailscale, host: "work-mac.tailnet.ts.net", port: 61234, priority: 10),
        ]),
        try rpcAttachTicketFrame(route: advertisedRoute, workspaceID: "dns-workspace"),
        try rpcWorkspaceListFrame(workspaceID: "dns-workspace", title: "DNS Workspace"),
    ])
    let runtime = testRuntime(
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
        #expect(host == "work-mac.tailnet.ts.net")
        #expect(port == 61234)
    } else {
        Issue.record("manual DNS route should switch to the advertised Tailscale host/port")
    }
}

@MainActor
@Test func manualHostPairingRejectsLANHostWhenMacDoesNotAdvertiseSecureRoute() async throws {
    let responses = ScriptedTransportResponses([
        try rpcHostStatusFrame(routes: []),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Studio LAN", host: "192.168.1.77", port: 15432)

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError == "Use your Mac's Tailscale MagicDNS name, or pair with a QR/link from that Mac.")
}

@MainActor
@Test func manualHostPairingTimesOutWrongHostWithoutStayingConnected() async throws {
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
    )
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: HangingTransportFactory(),
        rpcRequestTimeoutNanoseconds: 1_000_000
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Slow Mac", host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)

    #expect(route.kind == .tailscale)
    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError == "The Mac did not respond. Check the host and port, then try again.")
}

@MainActor
@Test func manualHostPairingUsesLoopbackRouteForLocalhost() async throws {
    let attachRoute = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let responses = ScriptedTransportResponses([
        try rpcAttachTicketFrame(route: attachRoute, workspaceID: "local-workspace"),
        try rpcWorkspaceListFrame(workspaceID: "local-workspace", title: "Local Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)

    let route = try #require(store.activeRoute)
    #expect(store.phase == .workspaces)
    #expect(store.connectedHostName == "127.0.0.1")
    #expect(route.kind == .debugLoopback)
    if case let .hostPort(host, port) = route.endpoint {
        #expect(host == "127.0.0.1")
        #expect(port == CmxMobileDefaults.defaultHostPort)
    } else {
        Issue.record("manual loopback route should use host/port")
    }
}

@MainActor
@Test func debugLoopbackAttachURLRejectsNonLoopbackHostBeforeStackAuth() async throws {
    let route = try hostPortRoute(kind: .debugLoopback, host: "203.0.113.9", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: "local-workspace",
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.activeTicket == nil)
    #expect(store.activeRoute == nil)
    #expect(store.connectionError == "Use your Mac's Tailscale MagicDNS name, or pair with a QR/link from that Mac.")
    #expect(try await responses.sentRequests().isEmpty)
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
@Test func uuidAttachTicketListsScopedWorkspace() async throws {
    let workspaceID = UUID().uuidString
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
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
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let requests = try await responses.sentRequests()
    let workspaceList = try #require(requests.first { $0.method == "workspace.list" })
    #expect(workspaceList.workspaceID == workspaceID)
    #expect(store.selectedWorkspace?.id.rawValue == workspaceID)
}

@MainActor
@Test func expiredAttachTicketFallsBackToStackAuthForScopedWorkspace() async throws {
    let ticketExpiresAt = Date().addingTimeInterval(60)
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
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
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-after-ticket-expiry",
        now: { ticketExpiresAt.addingTimeInterval(1) }
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let workspaceList = try #require(await responses.sentRequests().first { $0.method == "workspace.list" })
    #expect(workspaceList.attachToken == nil)
    #expect(workspaceList.stackAccessToken == "stack-token-after-ticket-expiry")
    #expect(store.selectedWorkspace?.id.rawValue == "expired-workspace")
}

@MainActor
@Test func manualHostPairingDoesNotSendStackAuthToCGNATAddress() async throws {
    let responses = ScriptedTransportResponses([
        try rpcHostStatusFrame(routes: [
            try routePayload(
                kind: .tailscale,
                host: "100.71.210.41",
                port: CmxMobileDefaults.defaultHostPort,
                priority: 10
            ),
        ]),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-must-not-leak"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Work Mac", host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError == "Use your Mac's Tailscale MagicDNS name, or pair with a QR/link from that Mac.")
    let requests = try await responses.sentRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.method == "mobile.host.status")
    #expect(requests.first?.hasAuth == false)
}

@MainActor
@Test func manualHostPairingRejectsInvalidHost() async {
    let store = CMUXMobileShellStore.preview()

    store.signIn()
    await store.connectManualHost(name: "Bad Host", host: "dev box.local", port: CmxMobileDefaults.defaultHostPort)

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
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let responses = ScriptedTransportResponses([
        try rpcAttachTicketFrame(route: route, workspaceID: "local-workspace"),
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
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)

    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.terminals.first?.lines.first == "Terminal surface is still starting.")
}

@MainActor
@Test func workspaceListPrefersReadyTerminalBeforeSnapshotRefresh() async throws {
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let responses = ScriptedTransportResponses([
        try rpcAttachTicketFrame(route: route, workspaceID: "local-workspace"),
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
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)

    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.id.rawValue == "local-workspace")
    #expect(store.selectedTerminalID?.rawValue == "ready-terminal")
    #expect(store.selectedWorkspace?.terminals.first { $0.id.rawValue == "ready-terminal" }?.lines.first == "ready terminal")
}

@MainActor
@Test func notReadySelectedTerminalFallsBackToReadyTerminalInAnotherWorkspace() async throws {
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let responses = ScriptedTransportResponses([
        try rpcAttachTicketFrame(route: route, workspaceID: "stale-workspace"),
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
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)

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
@Test func remoteCreateWorkspaceKeepsCreatedWorkspaceSelectedAfterTicketAttach() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-main",
        terminalID: "terminal-build",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
    var responseFrames = [
        try rpcWorkspaceListFrame(
            workspaceID: "workspace-main",
            title: "cmux",
            terminalID: "terminal-build"
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "workspace-main",
            terminalID: "terminal-build",
            visibleLines: ["initial"]
        ),
        try rpcWorkspaceCreateFrame(),
    ]
    for _ in 0..<8 {
        responseFrames.append(
            try rpcSnapshotResultFrame(
                workspaceID: "workspace-3",
                terminalID: "workspace-3-terminal-1",
                visibleLines: [
                    "$ cmux ios",
                    "workspace: Workspace 3",
                    "terminal: Terminal 1",
                ]
            )
        )
    }
    let responses = ScriptedTransportResponses(responseFrames)
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    store.createWorkspace()

    for _ in 0..<200 where store.selectedWorkspace?.id.rawValue != "workspace-3" ||
        store.selectedWorkspace?.terminals.first?.lines.contains("workspace: Workspace 3") != true {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(store.selectedWorkspace?.id.rawValue == "workspace-3")
    #expect(store.selectedTerminalID?.rawValue == "workspace-3-terminal-1")
    #expect(store.selectedWorkspace?.terminals.first?.lines.contains("workspace: Workspace 3") == true)
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

@Test func terminalBottomActionOutputsMatchReferenceAccessoryControls() {
    #expect(MobileTerminalBottomAction.escape.inputText(modifier: nil) == "\u{1B}")
    #expect(MobileTerminalBottomAction.tab.inputText(modifier: nil) == "\t")
    #expect(MobileTerminalBottomAction.returnKey.inputText(modifier: nil) == "\r")
    #expect(MobileTerminalBottomAction.upArrow.inputText(modifier: nil) == "\u{1B}[A")
    #expect(MobileTerminalBottomAction.downArrow.inputText(modifier: nil) == "\u{1B}[B")
    #expect(MobileTerminalBottomAction.leftArrow.inputText(modifier: nil) == "\u{1B}[D")
    #expect(MobileTerminalBottomAction.rightArrow.inputText(modifier: nil) == "\u{1B}[C")
    #expect(MobileTerminalBottomAction.ctrlC.inputText(modifier: nil) == "\u{03}")
    #expect(MobileTerminalBottomAction.ctrlD.inputText(modifier: nil) == "\u{04}")
    #expect(MobileTerminalBottomAction.ctrlZ.inputText(modifier: nil) == "\u{1A}")
    #expect(MobileTerminalBottomAction.ctrlL.inputText(modifier: nil) == "\u{0C}")
    #expect(MobileTerminalBottomAction.home.inputText(modifier: nil) == "\u{1B}[H")
    #expect(MobileTerminalBottomAction.end.inputText(modifier: nil) == "\u{1B}[F")
    #expect(MobileTerminalBottomAction.pageUp.inputText(modifier: nil) == "\u{1B}[5~")
    #expect(MobileTerminalBottomAction.pageDown.inputText(modifier: nil) == "\u{1B}[6~")
    #expect(MobileTerminalBottomAction.claude.inputText(modifier: nil) == "claude --dangerously-skip-permissions\r")
    #expect(MobileTerminalBottomAction.codex.inputText(modifier: nil)?.hasSuffix("--search\r") == true)
}

@Test func terminalBottomScrollableActionsReserveHideKeyboardForDedicatedButton() {
    #expect(MobileTerminalBottomAction.scrollableActionBarCases.first == .control)
    #expect(!MobileTerminalBottomAction.scrollableActionBarCases.contains(.hideKeyboard))
    #expect(MobileTerminalBottomAction.scrollableActionBarCases.count == MobileTerminalBottomAction.allCases.count - 1)
}

@Test func rawTerminalInputSendBufferBatchesPendingInputInOrder() {
    var buffer = MobileTerminalInputSendBuffer()

    let startsDrain = buffer.enqueue("p")
    let appendsWhileDraining = buffer.enqueue("rint")
    let appendsFinalCharacter = buffer.enqueue("f")
    #expect(startsDrain)
    #expect(!appendsWhileDraining)
    #expect(!appendsFinalCharacter)
    #expect(buffer.nextBatch() == "printf")

    let appendsSecondBatch = buffer.enqueue(" 'one'")
    #expect(!appendsSecondBatch)
    #expect(buffer.nextBatch() == " 'one'")
    #expect(buffer.nextBatch() == nil)

    let restartsDrain = buffer.enqueue("\r")
    #expect(restartsDrain)
    #expect(buffer.nextBatch() == "\r")
}

@Test func terminalBottomActionModifierOutputsMatchReferenceAccessoryControls() {
    #expect(MobileTerminalBottomAction.leftArrow.inputText(modifier: .alternate) == "\u{1B}b")
    #expect(MobileTerminalBottomAction.rightArrow.inputText(modifier: .alternate) == "\u{1B}f")
    #expect(MobileTerminalBottomAction.escape.inputText(modifier: .alternate) == "\u{1B}\u{1B}")
    #expect(MobileTerminalBottomAction.tab.inputText(modifier: .shift) == "\t")
    #expect(MobileTerminalBottomAction.leftArrow.inputText(modifier: .command) == "\u{01}")
    #expect(MobileTerminalBottomAction.rightArrow.inputText(modifier: .command) == "\u{05}")
    #expect(MobileTerminalBottomAction.upArrow.inputText(modifier: .control) == "\u{1B}[A")
}

@Test func terminalBottomActionModifiersBecomeStickyOnQuickDoubleTap() {
    let start = Date(timeIntervalSince1970: 100)
    var state = MobileTerminalModifierState()

    state.tap(.control, now: start)
    #expect(state.activeModifier == .control)
    #expect(!state.isSticky)

    state.tap(.control, now: start.addingTimeInterval(0.39))
    #expect(state.activeModifier == .control)
    #expect(state.isSticky)

    state.consumeAfterInput()
    #expect(state.activeModifier == .control)
    #expect(state.isSticky)

    state.tap(.control, now: start.addingTimeInterval(1))
    #expect(state.activeModifier == nil)
    #expect(!state.isSticky)
}

@Test func terminalBottomActionModifiersDisarmAfterSingleUseAndWhenSwitchingModifiers() {
    let start = Date(timeIntervalSince1970: 200)
    var state = MobileTerminalModifierState()

    state.tap(.alternate, now: start)
    state.tap(.shift, now: start.addingTimeInterval(0.1))
    #expect(state.activeModifier == .shift)
    #expect(!state.isSticky)

    state.consumeAfterInput()
    #expect(state.activeModifier == nil)

    state.tap(.command, now: start.addingTimeInterval(1))
    state.tap(.command, now: start.addingTimeInterval(1.5))
    #expect(state.activeModifier == nil)
    #expect(!state.isSticky)
}

@Test func terminalHiddenInputResolverHonorsSoftKeyboardModifiers() {
    #expect(MobileTerminalInputResolver.textInput("a", modifier: .control) == "\u{01}")
    #expect(MobileTerminalInputResolver.textInput("?", modifier: .control) == "\u{7F}")
    #expect(MobileTerminalInputResolver.textInput("word", modifier: .alternate) == "\u{1B}word")
    #expect(MobileTerminalInputResolver.textInput("k", modifier: .command) == "\u{0B}")
    #expect(MobileTerminalInputResolver.textInput("hi", modifier: .shift) == "HI")
    #expect(MobileTerminalInputResolver.textInput("\n", modifier: nil) == "\r")
}

@Test func terminalHiddenInputResolverBackspaceMatchesReferenceBehavior() {
    #expect(MobileTerminalInputResolver.backspaceInput(modifier: nil) == "\u{7F}")
    #expect(MobileTerminalInputResolver.backspaceInput(modifier: .control) == "\u{7F}")
    #expect(MobileTerminalInputResolver.backspaceInput(modifier: .command) == "\u{15}")
    #expect(MobileTerminalInputResolver.backspaceInput(modifier: .alternate) == "\u{1B}\u{7F}")
}

@MainActor
@Test func submittedTerminalInputStillAppendsCarriageReturn() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["ready"]
        ),
        try rpcResultFrame(result: ["accepted": true]),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["sent"]
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    store.terminalInputText = "echo hi"
    await store.submitTerminalInput()

    let inputRequest = try #require(await responses.sentRequests().first { $0.method == "terminal.input" })
    #expect(inputRequest.text == "echo hi\r")
    #expect(store.terminalInputText.isEmpty)
}

@MainActor
@Test func rawTerminalInputDoesNotAppendCarriageReturn() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["ready"]
        ),
        try rpcResultFrame(result: ["accepted": true]),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["raw sent"]
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    await store.submitTerminalRawInput("\u{1B}[A")

    let inputRequest = try #require(await responses.sentRequests().first { $0.method == "terminal.input" })
    #expect(inputRequest.text == "\u{1B}[A")
}

@MainActor
@Test func terminalSnapshotRequestIncludesReportedViewportSize() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["ready"]
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["resized"]
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["resized again"]
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    store.reportTerminalViewport(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        viewportSize: MobileTerminalViewportSize(columns: 52, rows: 24)
    )
    await store.openWorkspace("live-workspace")

    let requests = try await responses.sentRequests()
    let snapshotRequests = requests.filter { $0.method == "terminal.snapshot" }
    let viewportSnapshot = try #require(snapshotRequests.last { $0.viewportColumns != nil })
    #expect(viewportSnapshot.viewportColumns == 52)
    #expect(viewportSnapshot.viewportRows == 24)
    #expect(viewportSnapshot.maxScrollbackRows != nil)
    #expect((viewportSnapshot.maxScrollbackRows ?? 0) <= 120)
    #expect(viewportSnapshot.clientID?.isEmpty == false)
}

@Test func terminalSnapshotRequestPolicyCapsWideViewportScrollbackBelowFrameBudget() {
    let phoneRows = MobileTerminalSnapshotRequestPolicy.maxScrollbackRows(
        viewportSize: MobileTerminalViewportSize(columns: 54, rows: 42)
    )
    let wideRows = MobileTerminalSnapshotRequestPolicy.maxScrollbackRows(
        viewportSize: MobileTerminalViewportSize(columns: 300, rows: 120)
    )

    #expect(phoneRows == 120)
    #expect(wideRows >= 0)
    #expect(wideRows < 120)
    #expect(wideRows < 500)
}

@MainActor
@Test func terminalSnapshotDecodeValidatesSnapshotBeforeRendering() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcResultFrame(
            result: [
                "workspace_id": "live-workspace",
                "surface_id": "live-terminal",
                "snapshot": invalidSnapshotObject(terminalID: "live-terminal"),
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

    #expect(store.connectionError == "Could not connect to the Mac runtime.")
    #expect(store.selectedWorkspace?.terminals.first?.lines.contains("invalid") != true)
}

@MainActor
@Test func duplicateViewportReportRefreshesSnapshotWhenCurrentSnapshotHasNoViewportFit() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let viewportFit: [String: Any] = [
        "effective": ["columns": 52, "rows": 24],
        "client": ["columns": 52, "rows": 24],
        "is_current_client_limiting": true,
    ]
    var responseFrames = [
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["mac-sized first snapshot"]
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["viewport-sized refresh"],
            viewportFit: viewportFit
        ),
    ]
    for _ in 0..<10 {
        responseFrames.append(
            try rpcSnapshotResultFrame(
                workspaceID: "live-workspace",
                terminalID: "live-terminal",
                visibleLines: ["settled viewport refresh"],
                viewportFit: viewportFit
            )
        )
    }
    let responses = ScriptedTransportResponses(responseFrames)
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    store.reportTerminalViewport(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        viewportSize: MobileTerminalViewportSize(columns: 52, rows: 24)
    )
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    store.reportTerminalViewport(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        viewportSize: MobileTerminalViewportSize(columns: 52, rows: 24)
    )
    var requests = try await responses.sentRequests()
    for _ in 0..<40
        where requests.filter({ $0.method == "terminal.snapshot" }).count < 3
            || store.selectedWorkspace?.terminals.first?.lines.first != "settled viewport refresh" {
        try await Task.sleep(nanoseconds: 10_000_000)
        requests = try await responses.sentRequests()
    }
    let snapshotRequests = requests.filter { $0.method == "terminal.snapshot" }
    #expect(snapshotRequests.count >= 3)
    #expect(snapshotRequests.last?.viewportColumns == 52)
    #expect(snapshotRequests.last?.viewportRows == 24)
    #expect(store.selectedWorkspace?.terminals.first?.lines.first == "settled viewport refresh")
}

@MainActor
@Test func terminalSnapshotStoresViewportFitForVisibleAreaBorder() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["ready"],
            viewportFit: [
                "effective": ["columns": 52, "rows": 24],
                "client": ["columns": 120, "rows": 40],
                "is_current_client_limiting": false,
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

    let terminal = try #require(store.selectedWorkspace?.terminals.first { $0.id.rawValue == "live-terminal" })
    #expect(terminal.viewportFit?.effective == MobileTerminalViewportSize(columns: 52, rows: 24))
    #expect(terminal.viewportFit?.client == MobileTerminalViewportSize(columns: 120, rows: 40))
    #expect(terminal.viewportFit?.shouldDrawVisibleAreaBorder == true)
    #expect(TerminalVisibleAreaBorderPolicy.shouldDraw(viewportFit: terminal.viewportFit) == true)
}

@Test func terminalVisibleAreaBorderPolicyHidesOnLimitingDevices() {
    let limitingFit = MobileTerminalViewportFit(
        effective: MobileTerminalViewportSize(columns: 52, rows: 24),
        client: MobileTerminalViewportSize(columns: 52, rows: 24),
        isCurrentClientLimiting: true
    )
    let nonLimitingFit = MobileTerminalViewportFit(
        effective: MobileTerminalViewportSize(columns: 52, rows: 24),
        client: MobileTerminalViewportSize(columns: 120, rows: 40),
        isCurrentClientLimiting: false
    )
    let heightLimitingFit = MobileTerminalViewportFit(
        effective: MobileTerminalViewportSize(columns: 52, rows: 24),
        client: MobileTerminalViewportSize(columns: 120, rows: 24),
        isCurrentClientLimiting: true
    )
    let widthLimitingFit = MobileTerminalViewportFit(
        effective: MobileTerminalViewportSize(columns: 52, rows: 24),
        client: MobileTerminalViewportSize(columns: 52, rows: 40),
        isCurrentClientLimiting: true
    )

    #expect(TerminalVisibleAreaBorderPolicy.shouldDraw(viewportFit: nil) == false)
    #expect(TerminalVisibleAreaBorderPolicy.shouldDraw(viewportFit: limitingFit) == false)
    #expect(TerminalVisibleAreaBorderPolicy.shouldDraw(viewportFit: nonLimitingFit) == true)
    #expect(TerminalVisibleAreaBorderPolicy.edges(viewportFit: heightLimitingFit) == TerminalVisibleAreaBorderEdges(drawRight: true, drawBottom: false))
    #expect(TerminalVisibleAreaBorderPolicy.edges(viewportFit: widthLimitingFit) == TerminalVisibleAreaBorderEdges(drawRight: false, drawBottom: true))
    #expect(TerminalVisibleAreaBorderPolicy.edges(viewportFit: nonLimitingFit) == TerminalVisibleAreaBorderEdges(drawRight: true, drawBottom: true))
}

@Test func terminalSafeAreaExpansionAccountsForIPadSidebarVisibility() {
    #expect(
        MobileTerminalSafeAreaExpansionPolicy.edges(
            context: .fullWidth,
            hasCompactVerticalSize: true
        ) == MobileTerminalSafeAreaExpansionEdges(horizontal: true, bottom: true)
    )
    #expect(
        MobileTerminalSafeAreaExpansionPolicy.edges(
            context: .fullWidth,
            hasCompactVerticalSize: false
        ) == MobileTerminalSafeAreaExpansionEdges(horizontal: false, bottom: true)
    )
    #expect(
        MobileTerminalSafeAreaExpansionPolicy.edges(
            context: .splitSidebarVisible,
            hasCompactVerticalSize: true
        ) == MobileTerminalSafeAreaExpansionEdges(horizontal: false, bottom: true)
    )
    #expect(
        MobileTerminalSafeAreaExpansionPolicy.edges(
            context: .fullWidth,
            hasCompactVerticalSize: true,
            includesBottom: false
        ) == MobileTerminalSafeAreaExpansionEdges(horizontal: true, bottom: false)
    )
}

@Test func terminalContentSafeAreaInsetsProtectLandscapeCameraArea() {
    let landscapeInsets = SwiftUI.EdgeInsets(top: 0, leading: 54, bottom: 0, trailing: 21)

    #expect(
        MobileTerminalContentSafeAreaPolicy.horizontalInsets(
            context: .fullWidth,
            hasCompactVerticalSize: true,
            safeAreaInsets: landscapeInsets
        ) == MobileTerminalContentInsets(leading: 33, trailing: 0)
    )

    #expect(
        MobileTerminalContentSafeAreaPolicy.horizontalInsets(
            context: .fullWidth,
            hasCompactVerticalSize: true,
            safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 59)
        ) == MobileTerminalContentInsets(leading: 0, trailing: 59)
    )

    #expect(
        MobileTerminalContentSafeAreaPolicy.horizontalInsets(
            context: .fullWidth,
            hasCompactVerticalSize: true,
            safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 59),
            symmetricCameraEdge: .leading
        ) == MobileTerminalContentInsets(leading: 59, trailing: 0)
    )

    #expect(
        MobileTerminalContentSafeAreaPolicy.horizontalInsets(
            context: .fullWidth,
            hasCompactVerticalSize: true,
            safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 59),
            symmetricCameraEdge: .none
        ) == .zero
    )

    #expect(
        MobileTerminalContentSafeAreaPolicy.horizontalInsets(
            context: .fullWidth,
            hasCompactVerticalSize: true,
            safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 21, bottom: 0, trailing: 54)
        ) == MobileTerminalContentInsets(leading: 0, trailing: 33)
    )

    #expect(
        MobileTerminalContentSafeAreaPolicy.horizontalInsets(
            context: .fullWidth,
            hasCompactVerticalSize: true,
            safeAreaInsets: SwiftUI.EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 8)
        ) == .zero
    )
    #expect(
        MobileTerminalContentSafeAreaPolicy.horizontalInsets(
            context: .fullWidth,
            hasCompactVerticalSize: false,
            safeAreaInsets: landscapeInsets
        ) == .zero
    )
    #expect(
        MobileTerminalContentSafeAreaPolicy.horizontalInsets(
            context: .splitSidebarVisible,
            hasCompactVerticalSize: true,
            safeAreaInsets: landscapeInsets
        ) == .zero
    )
}

@Test func terminalLandscapeCameraEdgeFollowsWindowOrientation() {
    #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .landscapeLeft) == .trailing)
    #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .landscapeRight) == .leading)
    #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .portrait) == .trailing)
    #expect(MobileTerminalLandscapeCameraEdgeResolver.edge(for: .unknown) == .trailing)
}

@Test func terminalInputAccessoryMatchesZigReferenceMetrics() {
    #expect(TerminalInputAccessoryVisualMetrics.barHeight == 44)
    #expect(TerminalInputAccessoryVisualMetrics.horizontalInset == 16)
    #expect(TerminalInputAccessoryVisualMetrics.buttonHeight == 28)
    #expect(TerminalInputAccessoryVisualMetrics.buttonMinWidth == 44)
    #expect(TerminalInputAccessoryVisualMetrics.buttonCornerRadius == 6)
    #expect(TerminalInputAccessoryVisualMetrics.hideKeyboardSymbolPointSize == 15)
    #expect(TerminalInputAccessoryVisualMetrics.nubSize == 34)
    #expect(TerminalInputAccessoryVisualMetrics.nubInnerDotSize == 12)
}

@Test func terminalBottomBarOnlyExpandsBottomSafeAreaWhenKeyboardIsHidden() {
    #expect(MobileTerminalShellSafeAreaPolicy.expandsBehindBottomSafeArea(isKeyboardVisible: false))
    #expect(!MobileTerminalShellSafeAreaPolicy.expandsBehindBottomSafeArea(isKeyboardVisible: true))
    #expect(MobileTerminalBottomBarPlacementPolicy.expandsBottomSafeArea(isKeyboardVisible: false))
    #expect(MobileTerminalBottomBarPlacementPolicy.expandsBottomSafeArea(isKeyboardVisible: true, softwareKeyboardOverlap: 0))
    #expect(!MobileTerminalBottomBarPlacementPolicy.expandsBottomSafeArea(isKeyboardVisible: true, softwareKeyboardOverlap: 240))
    #expect(MobileTerminalBottomBarVisibilityPolicy.showsInlineBar(isKeyboardVisible: false))
    #expect(MobileTerminalBottomBarVisibilityPolicy.showsInlineBar(isKeyboardVisible: true))
    #expect(
        MobileTerminalBottomBarPlacementPolicy.controlBottomOffset(
            safeAreaBottom: 21,
            expandsSafeArea: true
        ) == 21
    )
    #expect(
        MobileTerminalBottomBarPlacementPolicy.controlBottomOffset(
            safeAreaBottom: 21,
            expandsSafeArea: false
        ) == 0
    )
}

@Test func terminalBottomActionSelectionDoesNotArmPlainActions() {
    var state = MobileTerminalModifierState()

    #expect(TerminalBottomActionSelectionPolicy.isArmed(action: .escape, modifierState: state) == false)
    #expect(TerminalBottomActionSelectionPolicy.isArmed(action: .control, modifierState: state) == false)

    state.tap(.control, now: Date(timeIntervalSince1970: 1))

    #expect(TerminalBottomActionSelectionPolicy.isArmed(action: .control, modifierState: state) == true)
    #expect(TerminalBottomActionSelectionPolicy.isArmed(action: .escape, modifierState: state) == false)
    #expect(TerminalBottomActionSelectionPolicy.isArmed(action: .zoomIn, modifierState: state) == false)
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

@Test func terminalRowProjectionPadsToViewportColumnCount() {
    let row = MobileTerminalGhosttyRow(cells: [
        MobileTerminalGhosttyCell(text: "|"),
        MobileTerminalGhosttyCell(text: " "),
    ])

    let cells = TerminalRowCellProjection.cells(
        from: row,
        preservingCursorColumn: nil,
        minimumColumnCount: 5
    )

    #expect(cells.count == 5)
    #expect(cells.first?.text == "|")
    #expect(cells.last?.text == " ")
}

private struct MissingTestStackAccessToken: Error {}

private func testRuntime(
    supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback, .websocket],
    transportFactory: any CmxByteTransportFactory,
    stackAccessToken: String? = "test-stack-token",
    rpcRequestTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000,
    now: @escaping @Sendable () -> Date = Date.init
) -> CMUXMobileRuntime {
    CMUXMobileRuntime(
        supportedRouteKinds: supportedRouteKinds,
        transportFactory: transportFactory,
        stackAccessTokenProvider: {
            guard let stackAccessToken else {
                throw MissingTestStackAccessToken()
            }
            return stackAccessToken
        },
        rpcRequestTimeoutNanoseconds: rpcRequestTimeoutNanoseconds,
        now: now
    )
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
        try rpcWorkspaceListFrame(workspaceID: workspaceID, title: title),
    ])
}

private func rpcWorkspaceListFrame(
    workspaceID: String,
    title: String,
    terminalID: String? = nil
) throws -> Data {
    let terminals: [[String: Any]]
    if let terminalID {
        terminals = [
            [
                "id": terminalID,
                "title": "Terminal",
                "current_directory": "/Users/test/project",
                "is_ready": true,
                "is_focused": true,
            ],
        ]
    } else {
        terminals = []
    }
    return try rpcResultFrame(
        result: [
            "workspaces": [
                [
                    "id": workspaceID,
                    "title": title,
                    "current_directory": "/Users/test/project",
                    "is_selected": true,
                    "terminals": terminals,
                ],
            ],
        ]
    )
}

private func rpcWorkspaceCreateFrame() throws -> Data {
    try rpcResultFrame(
        result: [
            "created_workspace_id": "workspace-3",
            "workspaces": [
                [
                    "id": "workspace-main",
                    "title": "cmux",
                    "current_directory": "/Users/test/project",
                    "is_selected": false,
                    "terminals": [
                        [
                            "id": "terminal-build",
                            "title": "Build",
                            "current_directory": "/Users/test/project",
                            "is_ready": true,
                            "is_focused": false,
                        ],
                    ],
                ],
                [
                    "id": "workspace-3",
                    "title": "Workspace 3",
                    "current_directory": "/Users/test/workspace-3",
                    "is_selected": true,
                    "terminals": [
                        [
                            "id": "workspace-3-terminal-1",
                            "title": "Terminal 1",
                            "current_directory": "/Users/test/workspace-3",
                            "is_ready": true,
                            "is_focused": true,
                        ],
                    ],
                ],
            ],
        ]
    )
}

private func rpcAttachTicketFrame(
    route: CmxAttachRoute,
    workspaceID: String,
    terminalID: String? = nil
) throws -> Data {
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: nil,
        routes: [route],
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        authToken: "ticket-secret"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let ticketObject = try JSONSerialization.jsonObject(with: encoder.encode(ticket))
    return try rpcResultFrame(result: ["ticket": ticketObject])
}

private func rpcHostStatusFrame(routes: [[String: Any]]) throws -> Data {
    try rpcResultFrame(
        result: [
            "host_service": [
                "is_running": true,
                "port": CmxMobileDefaults.defaultHostPort,
                "routes": routes,
                "active_connection_count": 1,
                "last_error": NSNull(),
            ],
        ]
    )
}

private func hostPortRoute(
    kind: CmxAttachTransportKind,
    host: String,
    port: Int,
    priority: Int = 0
) throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: kind.rawValue,
        kind: kind,
        endpoint: .hostPort(host: host, port: port),
        priority: priority
    )
}

private func routePayload(
    kind: CmxAttachTransportKind,
    host: String,
    port: Int,
    priority: Int
) throws -> [String: Any] {
    [
        "id": kind.rawValue,
        "kind": kind.rawValue,
        "endpoint": [
            "type": "host_port",
            "host": host,
            "port": port,
        ],
        "priority": priority,
    ]
}

private struct ScriptedTransportFactory: CmxByteTransportFactory {
    let responses: ScriptedTransportResponses

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        ScriptedTransport(responses: responses)
    }
}

private actor ScriptedTransportResponses {
    private var frames: [Data]
    private var sentPayloads: [Data] = []

    init(_ frames: [Data]) {
        self.frames = frames
    }

    func next() -> Data? {
        guard !frames.isEmpty else {
            return nil
        }
        return frames.removeFirst()
    }

    func recordSend(_ data: Data) throws {
        var buffer = data
        sentPayloads.append(contentsOf: try MobileSyncFrameCodec.decodeFrames(from: &buffer))
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map { payload in
            let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let params = request["params"] as? [String: Any] ?? [:]
            let auth = request["auth"] as? [String: Any]
            return RecordedRPCRequest(
                method: request["method"] as? String,
                workspaceID: params["workspace_id"] as? String,
                viewportColumns: params["viewport_columns"] as? Int,
                viewportRows: params["viewport_rows"] as? Int,
                maxScrollbackRows: params["max_scrollback_rows"] as? Int,
                clientID: params["client_id"] as? String,
                text: params["text"] as? String,
                hasAuth: auth != nil,
                attachToken: auth?["attach_token"] as? String,
                stackAccessToken: auth?["stack_access_token"] as? String
            )
        }
    }
}

private struct RecordedRPCRequest: Sendable {
    var method: String?
    var workspaceID: String?
    var viewportColumns: Int?
    var viewportRows: Int?
    var maxScrollbackRows: Int?
    var clientID: String?
    var text: String?
    var hasAuth: Bool
    var attachToken: String?
    var stackAccessToken: String?
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

    func send(_ data: Data) async throws {
        try await responses.recordSend(data)
    }

    func close() async {}
}

private struct HangingTransportFactory: CmxByteTransportFactory {
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        HangingTransport()
    }
}

private actor HangingTransport: CmxByteTransport {
    func connect() async throws {}

    func receive() async throws -> Data? {
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        return nil
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
    visibleLines: [String],
    viewportFit: [String: Any]? = nil
) throws -> Data {
    let snapshot = try MobileTerminalGhosttySnapshot.fixture(
        terminalID: terminalID,
        visibleLines: visibleLines
    )
    let snapshotObject = try JSONSerialization.jsonObject(with: snapshot.encodedValidatedJSON())
    var result: [String: Any] = [
        "workspace_id": workspaceID,
        "surface_id": terminalID,
        "snapshot": snapshotObject,
    ]
    if let viewportFit {
        result["viewport_fit"] = viewportFit
    }
    return try rpcResultFrame(result: result)
}

private func invalidSnapshotObject(terminalID: String) throws -> [String: Any] {
    let snapshot = try MobileTerminalGhosttySnapshot.fixture(
        terminalID: terminalID,
        rows: 2,
        visibleLines: ["invalid"]
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: snapshot.encodedValidatedJSON()) as? [String: Any]
    )
    object["visibleRows"] = []
    return object
}
