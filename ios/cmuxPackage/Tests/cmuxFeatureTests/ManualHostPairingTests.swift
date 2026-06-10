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


// MARK: - Manual host pairing routes + validation
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
@Test func manualHostPairingUsesNetworkRouteForPrivateLANIPWithStackAuth() async throws {
    let responses = ScriptedTransportResponses([
        try rpcErrorFrame(code: "method_not_found", message: "unknown method"),
        try rpcWorkspaceListFrame(workspaceID: "lan-workspace", title: "LAN Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-for-lan"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Studio LAN", host: " 192.168.1.77 ", port: 15432)

    let route = try #require(store.activeRoute)
    #expect(store.phase == .workspaces)
    #expect(store.connectionState == .connected)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "Studio LAN")
    if case let .hostPort(host, port) = route.endpoint {
        #expect(host == "192.168.1.77")
        #expect(port == 15432)
    } else {
        Issue.record("manual LAN route should use host/port")
    }
    #expect(route.kind == .tailscale)
    let requests = try await responses.sentRequests()
    #expect(requests.map(\.method) == ["mobile.attach_ticket.create", "workspace.list"])
    #expect(requests.allSatisfy { $0.stackAccessToken == "stack-token-for-lan" })
    #expect(requests.allSatisfy { $0.attachToken == nil })
}

@MainActor
@Test func manualHostPairingUsesNetworkRouteForLocalDNSNameWithStackAuth() async throws {
    let responses = ScriptedTransportResponses([
        try rpcErrorFrame(code: "method_not_found", message: "unknown method"),
        try rpcWorkspaceListFrame(workspaceID: "local-dns-workspace", title: "Local DNS Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-for-local-dns"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "devbox.local", port: 61234)

    let route = try #require(store.activeRoute)
    #expect(store.phase == .workspaces)
    #expect(store.connectionState == .connected)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "devbox.local")
    if case let .hostPort(host, port) = route.endpoint {
        #expect(host == "devbox.local")
        #expect(port == 61234)
    } else {
        Issue.record("manual local DNS route should use host/port")
    }
    #expect(route.kind == .tailscale)
    let requests = try await responses.sentRequests()
    #expect(requests.map(\.method) == ["mobile.attach_ticket.create", "workspace.list"])
    #expect(requests.allSatisfy { $0.stackAccessToken == "stack-token-for-local-dns" })
    #expect(requests.allSatisfy { $0.attachToken == nil })
}

@MainActor
@Test func manualHostPairingProbesLANHostForAttachTicketBeforeStackAuthFallback() async throws {
    let responses = ScriptedTransportResponses([
        try rpcErrorFrame(code: "method_not_found", message: "unknown method"),
        try rpcWorkspaceListFrame(workspaceID: "manual-workspace", title: "Manual Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-for-fallback"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Studio LAN", host: "192.168.1.77", port: 15432)

    #expect(store.phase == .workspaces)
    #expect(store.connectionState == .connected)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "Studio LAN")
    let requests = try await responses.sentRequests()
    #expect(requests.map(\.method) == ["mobile.attach_ticket.create", "workspace.list"])
    #expect(requests.allSatisfy { $0.stackAccessToken == "stack-token-for-fallback" })
    #expect(requests.allSatisfy { $0.attachToken == nil })
}

@MainActor
@Test func manualHostPairingTimesOutWrongHostWithoutStayingConnected() async throws {
    let route = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)
    )
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: HangingTransportFactory(),
        pairingRequestTimeoutNanoseconds: 1_000_000
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Slow Mac", host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)

    #expect(route.kind == .tailscale)
    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError == "No response from work-mac.tailnet.ts.net:58465. Make sure the host app is open and accepting mobile connections.")
}

@MainActor
@Test func cancelManualHostPairingDoesNotApplyDelayedTicket() async throws {
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let router = DelayedManualAttachTicketRouter(route: route)
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    let connectTask = Task { @MainActor in
        await store.connectManualHost(name: "Slow Mac", host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    }

    await router.waitForAttachTicketRequest()
    store.cancelPairing()
    await router.releaseAttachTicketResponse()
    await connectTask.value

    let requests = await router.sentRequests()
    #expect(requests.map(\.method) == ["mobile.attach_ticket.create"])
    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError == nil)
    #expect(store.activeTicket == nil)
    #expect(store.activeRoute == nil)
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
    #expect(store.connectionError == "This pairing route is not allowed. Enter a host and port, or pair with a QR/link from that computer.")
    #expect(try await responses.sentRequests().isEmpty)
}

@MainActor
@Test func manualHostPairingUsesNetworkRouteForTailscaleIP() async throws {
    let attachRoute = try hostPortRoute(
        kind: .tailscale,
        host: "100.71.210.41",
        port: CmxMobileDefaults.defaultHostPort
    )
    let responses = ScriptedTransportResponses([
        try rpcAttachTicketFrame(route: attachRoute, workspaceID: "tailscale-ip-workspace"),
        try rpcWorkspaceListFrame(workspaceID: "tailscale-ip-workspace", title: "Tailscale IP Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-for-tailscale-ip"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Work Mac", host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)

    let route = try #require(store.activeRoute)
    #expect(store.phase == .workspaces)
    #expect(store.connectionState == .connected)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "Work Mac")
    #expect(route.kind == .tailscale)
    if case let .hostPort(host, port) = route.endpoint {
        #expect(host == "100.71.210.41")
        #expect(port == CmxMobileDefaults.defaultHostPort)
    } else {
        Issue.record("manual Tailscale IP route should use host/port")
    }
    let attachTicketRequest = try #require(try await responses.sentRequests().first { $0.method == "mobile.attach_ticket.create" })
    #expect(attachTicketRequest.stackAccessToken == "stack-token-for-tailscale-ip")
}

@MainActor
@Test func manualHostPairingUsesNetworkRouteForDefaultPortLANHostWithStackAuth() async throws {
    let responses = ScriptedTransportResponses([
        try rpcErrorFrame(code: "method_not_found", message: "unknown method"),
        try rpcWorkspaceListFrame(workspaceID: "default-port-lan-workspace", title: "Default Port LAN Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-for-default-lan"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Work Mac", host: "192.168.1.77", port: CmxMobileDefaults.defaultHostPort)

    #expect(store.phase == .workspaces)
    #expect(store.connectionState == .connected)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "Work Mac")
    let route = try #require(store.activeRoute)
    #expect(route.kind == .tailscale)
    let requests = try await responses.sentRequests()
    #expect(requests.map(\.method) == ["mobile.attach_ticket.create", "workspace.list"])
    #expect(requests.allSatisfy { $0.stackAccessToken == "stack-token-for-default-lan" })
    #expect(requests.allSatisfy { $0.attachToken == nil })
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

