import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobilePairedMac
import CmuxMobileRPC
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI
import CmuxMobileShellModel
import CmuxMobileTransport
import CmuxMobileWorkspace
import Foundation
import StackAuth
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import cmuxFeature

/// Test collector that mounts a surface's ``CMUXMobileShellStore`` output stream
/// and accumulates each chunk's UTF-8 text, mirroring what a mounted
/// `GhosttySurfaceView` would feed into libghostty.
@MainActor
final class TerminalOutputCollector {
    private(set) var lines: [String] = []
    private var task: Task<Void, Never>?

    /// Begin consuming the surface's output stream into ``lines``.
    func mount(store: CMUXMobileShellStore, surfaceID: String) {
        task = Task { @MainActor [weak self] in
            for await chunk in store.terminalOutputStream(surfaceID: surfaceID) {
                guard let self else { break }
                self.lines.append(String(data: chunk.data, encoding: .utf8) ?? "")
                store.terminalOutputDidProcess(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken
                )
            }
        }
    }

    /// Stop consuming the stream, unregistering the surface from the store.
    func unmount() {
        task?.cancel()
        task = nil
    }
}

@MainActor
@Test func startsAtSignInWithoutConnection() {
    let store = CMUXMobileShellStore.preview()

    #expect(store.phase == .signIn)
    #expect(store.isSignedIn == false)
    #expect(store.connectionState == .disconnected)
    #expect(store.macConnectionStatus == .unavailable)
    #expect(store.selectedWorkspace?.name == "cmux")
    #expect(store.selectedTerminalID?.rawValue == "terminal-build")
}

@Test func authBuildPolicyCompilesDevShortcutOnlyForDebug() {
    #if CMUX_DEV_AUTH
    #expect(MobileAuthBuildPolicy.current.includesFortyTwoShortcut)
    #else
    #expect(!MobileAuthBuildPolicy.current.includesFortyTwoShortcut)
    #endif
}

@Test func authAutoLoginPolicyUsesRealStoredTokenState() {
    #expect(AuthLaunchOptions.shouldStartAutoLogin(hasCredentials: true, hasStoredTokens: false))
    #expect(!AuthLaunchOptions.shouldStartAutoLogin(hasCredentials: true, hasStoredTokens: true))
    #expect(!AuthLaunchOptions.shouldStartAutoLogin(hasCredentials: false, hasStoredTokens: false))
}

#if DEBUG
@Test func mobileDevStackAuthTokenProviderUsesExplicitEnvironmentOnly() {
    #expect(MobileShellDevStackAuthTokenProvider.token(environment: [:]) == nil)
    #expect(MobileShellDevStackAuthTokenProvider.token(environment: [
        MobileShellDevStackAuthTokenProvider.environmentKey: "   "
    ]) == nil)
    #expect(MobileShellDevStackAuthTokenProvider.token(environment: [
        MobileShellDevStackAuthTokenProvider.environmentKey: " cmux-dev-token "
    ]) == "cmux-dev-token")
}
#endif

// Auth error mapping + cached-session recovery are now owned and tested by
// CmuxAuthRuntime (AuthErrorMapperTests). The display-safe error and
// cached-session-validation assertions moved there with the AuthCoordinator
// lift; see Packages/Shared/CmuxAuthRuntime/Tests.

@Test func mobileRuntimeDefaultsToThirtySecondRPCTimeout() {
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: ScriptedTransportResponses([])),
        stackAccessTokenProvider: { "test-stack-token" }
    )

    #expect(runtime.rpcRequestTimeoutNanoseconds == 30 * 1_000_000_000)
    #expect(runtime.pairingRequestTimeoutNanoseconds == 8 * 1_000_000_000)
}

@Test func mobileRuntimeMapsTimedOutStackTokenToRequestTimeout() {
    guard case .requestTimedOut = CMUXMobileRuntime.connectionError(forStackAuthError: AuthError.timedOut) else {
        Issue.record("expected timed-out Stack token acquisition to stay retryable")
        return
    }
}

@MainActor
@Test func activeMacReconnectRouteSkipsUnsupportedLoopbackRoute() throws {
    let loopback = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let tailscale = try hostPortRoute(kind: .tailscale, host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)

    let route = CMUXMobileShellStore.firstReconnectHostPortRoute(
        [loopback, tailscale],
        supportedKinds: [.tailscale]
    )

    #expect(route?.0 == "100.71.210.41")
    #expect(route?.1 == CmxMobileDefaults.defaultHostPort)
}

@MainActor
@Test func rootAuthGateIgnoresLegacyShellSignInState() {
    let store = CMUXMobileShellStore.preview()

    store.signIn()

    #expect(store.isSignedIn)
    #expect(!MobileRootAuthGate.isAuthenticated(stackAuthenticated: false))
}

@MainActor
@Test func rootAuthGateSynchronizesStackAuthIntoShellStore() {
    let store = CMUXMobileShellStore.preview()

    MobileRootAuthGate.syncShellAuthentication(stackAuthenticated: true, store: store)

    #expect(store.isSignedIn)

    MobileRootAuthGate.syncShellAuthentication(stackAuthenticated: false, store: store)

    #expect(!store.isSignedIn)
    #expect(store.connectionState == .disconnected)
}

@MainActor
@Test func rootAuthGateKeepsShellSignedInWhileStackAuthRestores() {
    let store = CMUXMobileShellStore.preview()
    store.signIn()

    MobileRootAuthGate.syncShellAuthentication(
        stackAuthenticated: false,
        isRestoringSession: true,
        store: store
    )

    #expect(store.isSignedIn)
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
    #expect(store.macConnectionStatus == .connected)
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
    let result = await store.connectPairingURLResult(try payload.encodedURL().absoluteString)

    #expect(result == .needsUserApproval)
    #expect(store.pairingVersionWarning?.contains("unknown compatibility") == true)

    await store.acceptPairingVersionWarning()

    #expect(store.phase == .workspaces)
    #expect(store.connectedHostName == "Test Mac")
    #expect(store.macConnectionStatus == .connected)
    #expect(store.activeTicket?.macDeviceID == "test-mac")
    #expect(store.activeRoute?.kind == .debugLoopback)
    #expect(store.selectedWorkspace?.id.rawValue == "workspace-main")
}

@MainActor
@Test func macConnectionStatusMarksUnavailableWhenEventStreamCloses() async throws {
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcHostStatusFrame(renderGrid: true),
        try rpcResultFrame(result: ["stream_id": "events"]),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    for _ in 0..<200 {
        if store.macConnectionStatus == .unavailable {
            break
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    let requests = try await responses.sentRequests()
    #expect(requests.contains { $0.method == "mobile.events.subscribe" })
    #expect(store.connectionState == .connected)
    #expect(store.macConnectionStatus == .unavailable)
    #expect(store.connectionRecoveryFailed)
}

@MainActor
@Test func connectPreviewHostIgnoresPairingURLsForTrackedAsyncPath() async {
    let store = CMUXMobileShellStore.preview()

    store.signIn()
    store.pairingCode = "cmux-ios://attach?v=1&payload=invalid"
    store.connectPreviewHost()
    await Task.yield()

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError == nil)
}

@MainActor
@Test func expiredPairingURLPayloadIsRejectedBeforePreviewConnection() async throws {
    let json = """
    {
      "version": 1,
      "mac_device_id": "test-mac",
      "mac_display_name": "Test Mac",
      "host": "127.0.0.1",
      "port": 49831,
      "expires_at": "1970-01-01T00:00:01Z",
      "transport": "debug_loopback"
    }
    """
    let url = try #require(URL(string: "cmux-ios://pair?v=1&payload=\(base64URLEncode(Data(json.utf8)))"))
    let store = CMUXMobileShellStore.preview()

    store.signIn()
    let didConnect = await store.connectPairingURL(url.absoluteString)

    #expect(!didConnect)
    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.activeTicket == nil)
    // Assert the category's message rather than a literal so the test tracks
    // the invalid-code copy instead of breaking each time it is reworded.
    #expect(store.connectionError == MobilePairingFailureCategory.invalidCode.message)
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
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
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
@Test func supersededPairingURLReportsSupersededWithoutClearingNewerConnection() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56577)
    )
    let firstTicket = try CmxAttachTicket(
        workspaceID: "first-workspace",
        terminalID: "first-terminal",
        macDeviceID: "first-mac",
        macDisplayName: "First Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let secondTicket = try CmxAttachTicket(
        workspaceID: "second-workspace",
        terminalID: "second-terminal",
        macDeviceID: "second-mac",
        macDisplayName: "Second Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let router = SupersededAttachURLRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let firstURL = try attachURL(for: firstTicket).absoluteString
    let secondURL = try attachURL(for: secondTicket).absoluteString

    store.signIn()
    let firstTask = Task { @MainActor in
        await store.connectPairingURLResult(firstURL)
    }
    await router.waitForFirstWorkspaceListRequest()

    let secondResult = await store.connectPairingURLResult(secondURL)
    await router.releaseFirstWorkspaceListResponse()
    let firstResult = await firstTask.value

    #expect(secondResult == .connected)
    #expect(firstResult == .superseded)
    #expect(store.connectionState == .connected)
    #expect(store.connectedHostName == "Second Mac")
    #expect(store.selectedWorkspace?.id.rawValue == "second-workspace")
    #expect(store.activeTicket?.macDeviceID == "second-mac")
}

@MainActor
@Test func versionWarningDoesNotClearExistingConnectionBeforeApproval() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56577)
    )
    let activeTicket = try CmxAttachTicket(
        workspaceID: "active-workspace",
        terminalID: "active-terminal",
        macDeviceID: "active-mac",
        macDisplayName: "Active Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "active-ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "active-workspace", title: "Active Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback, .tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        feedbackStampProvider: {
            MobileFeedbackStamp(
                buildType: .dev,
                appVersion: "0.65.0",
                appBuild: "10",
                bundleIdentifier: "dev.cmux.ios.test",
                osVersion: "iOS test",
                deviceModel: "test"
            )
        }
    )

    store.signIn()
    let firstResult = await store.connectPairingURLResult(try attachURL(for: activeTicket).absoluteString)

    #expect(firstResult == .connected)
    #expect(store.connectionState == .connected)
    #expect(store.activeTicket?.macDeviceID == "active-mac")

    let warningResult = await store.connectPairingURLResult(
        "cmux-ios://attach?v=2&pc=2&av=0.65.0&ab=9&r=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)"
    )

    #expect(warningResult == .needsUserApproval)
    #expect(store.connectionState == .connected)
    #expect(store.activeTicket?.macDeviceID == "active-mac")
    #expect(store.pairingVersionWarning != nil)
    #expect(try await responses.sentRequests().count == 1)

    store.cancelPairing()

    #expect(store.pairingVersionWarning == nil)
    #expect(store.connectionState == .connected)
    #expect(store.activeTicket?.macDeviceID == "active-mac")
}

@MainActor
@Test func versionWarningSupersedesOlderPairingAttemptWithoutConnectingIt() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56577)
    )
    let slowTicket = try CmxAttachTicket(
        workspaceID: "first-workspace",
        terminalID: "first-terminal",
        macDeviceID: "first-mac",
        macDisplayName: "First Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let router = SupersededAttachURLRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback, .tailscale],
        transportFactory: RequestAwareTransportFactory(router: router)
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        feedbackStampProvider: {
            MobileFeedbackStamp(
                buildType: .dev,
                appVersion: "0.65.0",
                appBuild: "10",
                bundleIdentifier: "dev.cmux.ios.test",
                osVersion: "iOS test",
                deviceModel: "test"
            )
        }
    )

    store.signIn()
    let slowURL = try attachURL(for: slowTicket).absoluteString
    let slowTask = Task { @MainActor in
        await store.connectPairingURLResult(slowURL)
    }
    await router.waitForFirstWorkspaceListRequest()

    let warningResult = await store.connectPairingURLResult(
        "cmux-ios://attach?v=2&pc=2&av=0.65.0&ab=9&r=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)"
    )
    await router.releaseFirstWorkspaceListResponse()
    let slowResult = await slowTask.value

    #expect(warningResult == .needsUserApproval)
    #expect(slowResult == .superseded)
    #expect(store.connectionState == .disconnected)
    #expect(store.activeTicket == nil)
    #expect(store.pairingVersionWarning != nil)
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
    let expectedTicket = try ticket.withCurrentMacPairingCompatibilityVersionForTest()
    #expect(store.activeTicket == expectedTicket)
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
@Test func manualHostPairingRejectsPrivateLANIPWithoutSendingStackToken() async throws {
    // Plain private-LAN routes are dialed over unencrypted TCP, so
    // routeAllowsStackAuth excludes them: pairing must fail before any RPC
    // (and the Stack bearer token) leaves the device.
    let responses = ScriptedTransportResponses([])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-for-lan"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Studio LAN", host: " 192.168.1.77 ", port: 15432)

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.activeTicket == nil)
    #expect(store.activeRoute == nil)
    #expect(store.connectionError == "This pairing route is not allowed. Enter a host and port, or pair with a QR/link from that computer.")
    #expect(try await responses.sentRequests().isEmpty)
}

@MainActor
@Test func manualHostPairingRejectsLocalDNSNameWithoutSendingStackToken() async throws {
    // `.local`/Bonjour hosts are dialed over unencrypted TCP, so
    // routeAllowsStackAuth excludes them: pairing must fail before any RPC
    // (and the Stack bearer token) leaves the device.
    let responses = ScriptedTransportResponses([])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-for-local-dns"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "devbox.local", port: 61234)

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.activeTicket == nil)
    #expect(store.activeRoute == nil)
    #expect(store.connectionError == "This pairing route is not allowed. Enter a host and port, or pair with a QR/link from that computer.")
    #expect(try await responses.sentRequests().isEmpty)
}

@MainActor
@Test func manualHostPairingProbesTailscaleHostForAttachTicketBeforeStackAuthFallback() async throws {
    // A trusted (Tailscale) manual host is probed for a real attach ticket
    // first; an older Mac that does not implement the probe method falls back
    // to a synthetic ticket and Stack-authenticated workspace.list.
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
    await store.connectManualHost(name: "Work Mac", host: "100.71.210.41", port: 15432)

    #expect(store.phase == .workspaces)
    #expect(store.connectionState == .connected)
    #expect(store.connectionError == nil)
    #expect(store.connectedHostName == "Work Mac")
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
    // A handshake timeout to a Tailscale host now points the user at the real
    // cause (Mac asleep / off Tailscale) instead of wrongly blaming the host
    // app, and carries an actionable guidance line.
    #expect(store.connectionError == "No response from work-mac.tailnet.ts.net:58465. Your Mac may be asleep or off Tailscale. Make sure it's awake and on the same Tailscale network.")
    #expect(store.connectionErrorGuidance != nil)
}

@MainActor
@Test func manualHostPairingWhileOfflineFailsFastWithGuidanceAndNoDial() async throws {
    // Reachability preflight: a phone with no network path must fail the pair
    // immediately with the offline category and never dial a transport, instead
    // of letting the connect sit in NWConnection's `.waiting` state and stack
    // the per-route timeouts into the opaque ~60s wait the reporter saw.
    let dials = TransportDialRecorder()
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: RecordingNeverConnectTransportFactory(dials: dials)
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        reachability: OfflineReachability()
    )

    store.signIn()
    await store.connectManualHost(name: "Work Mac", host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    // Non-empty, offline-specific headline: the spinner can no longer revert
    // silently, and the message names the real problem (the phone is offline).
    #expect(store.connectionError == "This device looks offline. Connect to Wi-Fi or cellular, then try again.")
    // The offline headline carries the actionable guidance inline (connect to
    // Wi-Fi or cellular), so no separate guidance line is shown for it.
    #expect(store.connectionErrorGuidance == nil)
    // The preflight short-circuited before any transport was created.
    #expect(dials.count == 0)
}

@MainActor
@Test func qrPairingWhileOfflineFailsFastWithoutDial() async throws {
    let route = try hostPortRoute(kind: .tailscale, host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: UUID().uuidString,
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let dials = TransportDialRecorder()
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: RecordingNeverConnectTransportFactory(dials: dials)
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        reachability: OfflineReachability()
    )

    store.signIn()
    let result = await store.connectPairingURLResult(try attachURL(for: ticket).absoluteString)

    #expect(result == .failed)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError == "This device looks offline. Connect to Wi-Fi or cellular, then try again.")
    #expect(store.connectionErrorGuidance == nil)
    #expect(dials.count == 0)
}

@MainActor
@Test func expiredLegacyTicketWhileOfflineReportsOfflineNotExpired() async throws {
    // Expiry no longer classifies pairing inputs: a pairing QR never expires
    // (v2 codes carry no expiry, legacy `e=` values are dropped on decode, and
    // the host authorizes by Stack account, not ticket age), so a legacy
    // ticket whose `expiresAt` has passed is still a valid pairing input.
    // While the device is offline the preflight must say so and fail fast
    // with no dial — reconnecting and rescanning the same code is expected
    // to work, so "offline" is the honest, actionable message.
    let ticketExpiresAt = Date().addingTimeInterval(60)
    let route = try hostPortRoute(kind: .tailscale, host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: UUID().uuidString,
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
        routes: [route],
        expiresAt: ticketExpiresAt,
        authToken: "ticket-secret"
    )
    let dials = TransportDialRecorder()
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: RecordingNeverConnectTransportFactory(dials: dials),
        now: { ticketExpiresAt.addingTimeInterval(1) }
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        reachability: OfflineReachability()
    )

    store.signIn()
    let result = await store.connectPairingURLResult(try attachURL(for: ticket).absoluteString)

    #expect(result == .failed)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError == "This device looks offline. Connect to Wi-Fi or cellular, then try again.")
    #expect(store.connectionErrorGuidance == nil)
    #expect(dials.count == 0)
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
@Test func manualHostPairingToLoopbackStillDialsWhileOffline() async throws {
    // Loopback needs no external network path (simulator/dev pairing to
    // 127.0.0.1), so the offline reachability preflight must not block it.
    let attachRoute = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let responses = ScriptedTransportResponses([
        try rpcAttachTicketFrame(route: attachRoute, workspaceID: "local-workspace"),
        try rpcWorkspaceListFrame(workspaceID: "local-workspace", title: "Local Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        reachability: OfflineReachability()
    )

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)

    #expect(store.phase == .workspaces)
    #expect(store.connectionState == .connected)
    #expect(store.connectionError == nil)
    #expect(store.activeRoute?.kind == .debugLoopback)
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
@Test func qrPairingURLStillConnectsTenMinutesAfterMint() async throws {
    // The pairing QR encodes no expiry: a code that sat on the Mac's screen
    // for 10+ minutes (longer than the minted ticket's whole attach-token
    // TTL) must still pair. Before this grammar revision the phone refused
    // such a scan at connect time with "This pairing link expired".
    let mintedAt = Date()
    let route = try hostPortRoute(
        kind: .tailscale,
        host: "100.71.210.41",
        port: CmxMobileDefaults.defaultHostPort
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "qr-workspace",
        terminalID: nil,
        macDeviceID: "qr-mac",
        macDisplayName: "QR Mac",
        macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
        routes: [route],
        expiresAt: mintedAt.addingTimeInterval(600),
        authToken: "minted-but-never-in-the-qr"
    )
    // Encode exactly what the Mac's pairing window renders: the compact QR
    // grammar, which drops the token, the display name, and the expiry.
    let payload = try CmxAttachTicketCompactCoder().encode(ticket)
    let url = "cmux-ios://attach?v=\(ticket.version)&payload=\(base64URLEncode(payload))"
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "qr-workspace", title: "QR Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-outlives-the-qr",
        now: { mintedAt.addingTimeInterval(660) }
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(url)

    #expect(store.phase == .workspaces)
    #expect(store.connectionState == .connected)
    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.id.rawValue == "qr-workspace")
    // The QR carries no display name, so until `mobile.host.status` reports
    // one the device id stands in.
    #expect(store.connectedHostName == "qr-mac")
}

@MainActor
@Test func minimalPairingCodeConnectsAndAdoptsHostReportedIdentity() async throws {
    // The minimal v2 pairing code carries only Tailscale routes: no device
    // id, no display name. Both must be adopted post-handshake from
    // `mobile.host.status` so the connection becomes a persisted, named,
    // reconnectable paired Mac.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pairedMacStore = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("paired-macs.sqlite3"))
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "qr-workspace", title: "QR Workspace"),
        try rpcHostStatusFrame(
            renderGrid: true,
            macDeviceID: "status-reported-mac",
            macDisplayName: "Status Mac"
        ),
        try rpcResultFrame(result: ["stream_id": "events"]),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        pairedMacStore: pairedMacStore
    )

    store.signIn()
    await store.connectPairingURL("cmux-ios://attach?v=2&pc=1&r=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)")

    #expect(store.connectionState == .connected)
    // Until the status reply lands, the dialed Tailscale host stands in for
    // the name (the v2 ticket has neither name nor device id); the status
    // read runs on the event-listener task, so poll briefly instead of
    // racing it. The adoption lands in steps (ticket id, identity upsert,
    // then the display-name upsert on the serialized write chain), so poll
    // for the LAST durable write — the persisted display name — not just
    // the in-memory connectedHostName, which flips before that write lands.
    for _ in 0..<400 {
        if store.connectedHostName == "Status Mac",
           let saved = try? await pairedMacStore.activeMac(),
           saved.displayName == "Status Mac" { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(store.connectedHostName == "Status Mac")
    #expect(store.activeTicket?.macDeviceID == "status-reported-mac")
    let savedMac = try #require(try await pairedMacStore.activeMac())
    #expect(savedMac.macDeviceID == "status-reported-mac")
    #expect(savedMac.displayName == "Status Mac")
    #expect(savedMac.routes.contains { route in
        if case let .hostPort(host, _) = route.endpoint {
            return host == "100.71.210.41"
        }
        return false
    })
    #expect(store.hasKnownPairedMac)
}

@MainActor
@Test func minimalPairingCodeRequiresMatchingEmailBeforeDialing() async throws {
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "qr-workspace", title: "QR Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let analytics = RecordingAnalytics()
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        identityProvider: TestIdentityProvider(
            currentUserIDValue: "phone-user",
            currentUserEmailValue: "phone@example.com"
        ),
        analytics: analytics
    )

    store.signIn()
    let result = await store.connectPairingURLResult(
        "cmux-ios://attach?v=2&ub=mac-user&pc=1&r=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)"
    )

    #expect(result == .failed)
    #expect(store.connectionState == .disconnected)
    #expect(store.connectionError?.contains("same email") == true)
    #expect(store.connectionError?.contains("mac@example.com") == false)
    #expect(store.connectionError?.contains("phone@example.com") == false)
    #expect(analytics.eventCount(named: "ios_pairing_started") == 1)
    #expect(analytics.eventCount(named: "ios_pairing_failed") == 1)
    #expect(try await responses.sentRequests().isEmpty)
}

@MainActor
@Test func minimalPairingCodeWithUnknownPhoneEmailUsesHostAuth() async throws {
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "qr-workspace", title: "QR Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        identityProvider: TestIdentityProvider(
            currentUserIDValue: nil,
            currentUserEmailValue: nil
        )
    )

    store.signIn()
    let result = await store.connectPairingURLResult(
        "cmux-ios://attach?v=2&ub=mac-user&pc=1&r=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)"
    )

    #expect(result == .connected)
    #expect(store.connectionState == .connected)
    #expect(store.connectedHostName == "100.71.210.41")
    #expect(try await responses.sentRequests().contains { $0.method == "workspace.list" })
}

@MainActor
@Test func minimalPairingCodeCompatibilityMismatchWarnsAndContinuesAfterAcceptance() async throws {
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "qr-workspace", title: "QR Workspace"),
        try rpcHostStatusFrame(
            renderGrid: false,
            macDeviceID: "status-reported-mac",
            macDisplayName: "Status Mac"
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        supportsServerPushEvents: false
    )
    let analytics = RecordingAnalytics()
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        identityProvider: TestIdentityProvider(
            currentUserIDValue: "phone-user",
            currentUserEmailValue: "user@example.com"
        ),
        analytics: analytics,
        feedbackStampProvider: {
            MobileFeedbackStamp(
                buildType: .dev,
                appVersion: "0.65.0",
                appBuild: "10",
                bundleIdentifier: "dev.cmux.ios.test",
                osVersion: "iOS test",
                deviceModel: "test"
            )
        }
    )

    store.signIn()
    let result = await store.connectPairingURLResult(
        "cmux-ios://attach?v=2&ub=phone-user&pc=2&av=0.65.0&ab=9&r=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)"
    )

    #expect(result == .needsUserApproval)
    #expect(store.connectionState == .disconnected)
    #expect(store.pairingVersionWarning?.contains("0.65.0 (10)") == true)
    #expect(store.pairingVersionWarning?.contains("0.65.0 (9)") == true)
    #expect(analytics.eventCount(named: "ios_pairing_started") == 0)
    #expect(try await responses.sentRequests().isEmpty)

    await store.acceptPairingVersionWarning()

    #expect(store.pairingVersionWarning == nil)
    #expect(store.connectionState == .connected)
    #expect(store.selectedWorkspace?.id.rawValue == "qr-workspace")
    #expect(analytics.eventCount(named: "ios_pairing_started") == 1)
    #expect(analytics.eventCount(named: "ios_pairing_succeeded") == 1)
    #expect(try await responses.sentRequests().contains { $0.method == "workspace.list" })
}

@MainActor
@Test func minimalPairingCodeMissingCompatibilityWarnsBeforeDialing() async throws {
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "qr-workspace", title: "QR Workspace"),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        supportsServerPushEvents: false
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        identityProvider: TestIdentityProvider(
            currentUserIDValue: "phone-user",
            currentUserEmailValue: "user@example.com"
        ),
        feedbackStampProvider: {
            MobileFeedbackStamp(
                buildType: .dev,
                appVersion: "1.0.0",
                appBuild: "10",
                bundleIdentifier: "dev.cmux.ios.test",
                osVersion: "iOS test",
                deviceModel: "test"
            )
        }
    )

    store.signIn()
    let result = await store.connectPairingURLResult(
        "cmux-ios://attach?v=2&ub=phone-user&r=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)"
    )

    #expect(result == .needsUserApproval)
    #expect(store.connectionState == .disconnected)
    #expect(store.pairingVersionWarning?.contains("unknown compatibility") == true)
    #expect(try await responses.sentRequests().isEmpty)
}

@MainActor
@Test func minimalPairingCodeAppVersionMismatchDoesNotWarnWhenCompatibilityMatches() async throws {
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "qr-workspace", title: "QR Workspace"),
        try rpcHostStatusFrame(
            renderGrid: false,
            macDeviceID: "status-reported-mac",
            macDisplayName: "Status Mac"
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        supportsServerPushEvents: false
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        identityProvider: TestIdentityProvider(
            currentUserIDValue: "phone-user",
            currentUserEmailValue: "user@example.com"
        ),
        feedbackStampProvider: {
            MobileFeedbackStamp(
                buildType: .dev,
                appVersion: "1.0.0",
                appBuild: "10",
                bundleIdentifier: "dev.cmux.ios.test",
                osVersion: "iOS test",
                deviceModel: "test"
            )
        }
    )

    store.signIn()
    let result = await store.connectPairingURLResult(
        "cmux-ios://attach?v=2&ub=phone-user&pc=1&av=0.65.0&ab=95&r=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)"
    )

    #expect(result == .connected)
    #expect(store.pairingVersionWarning == nil)
    #expect(store.connectionState == .connected)
    #expect(store.selectedWorkspace?.id.rawValue == "qr-workspace")
}

@MainActor
@Test func minimalPairingCodePersistsPairedMacWithoutServerPushEvents() async throws {
    // Identity recovery for an anonymous v2 ticket must not be coupled to
    // the push-event listener: on a runtime without server-push events the
    // listener (whose status probe normally performs the recovery) never
    // starts, and before the connect-seam scheduling a QR pair connected
    // fine but the Mac was never persisted (no reconnect-on-launch, no host
    // switcher entry).
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pairedMacStore = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("paired-macs.sqlite3"))
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(workspaceID: "qr-workspace", title: "QR Workspace"),
        try rpcHostStatusFrame(
            renderGrid: false,
            macDeviceID: "status-reported-mac",
            macDisplayName: "Status Mac"
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        supportsServerPushEvents: false
    )
    let store = CMUXMobileShellStore(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        pairedMacStore: pairedMacStore
    )

    store.signIn()
    await store.connectPairingURL("cmux-ios://attach?v=2&pc=1&r=100.71.210.41:\(CmxMobileDefaults.defaultHostPort)")

    #expect(store.connectionState == .connected)
    // The recovery request runs on its own task; poll briefly instead of
    // racing it. The adopted device id lands first, then the identity
    // upsert, then the display-name application + upsert on the serialized
    // write chain — so poll for the LAST durable write (the persisted
    // display name), not the first in-memory step.
    for _ in 0..<400 {
        if store.activeTicket?.macDeviceID == "status-reported-mac",
           store.connectedHostName == "Status Mac",
           let saved = try? await pairedMacStore.activeMac(),
           saved.displayName == "Status Mac" { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(store.activeTicket?.macDeviceID == "status-reported-mac")
    #expect(store.connectedHostName == "Status Mac")
    let savedMac = try #require(try await pairedMacStore.activeMac())
    #expect(savedMac.macDeviceID == "status-reported-mac")
    #expect(savedMac.displayName == "Status Mac")
    #expect(store.hasKnownPairedMac)
}

@MainActor
@Test func scannedLoopbackPairingCodeIsRejectedWithGuidance() async throws {
    // "QR shouldn't work for localhost": a scanned/pasted v2 code whose
    // routes point at the phone itself fails closed with copy that names the
    // actual fix (Tailscale), instead of dialing 127.0.0.1 and burning the
    // whole request timeout before a generic connect error.
    let store = CMUXMobileShellStore.preview()

    store.signIn()
    let result = await store.connectPairingURLResult("cmux-ios://attach?v=2&r=127.0.0.1:\(CmxMobileDefaults.defaultHostPort)")

    #expect(result == .failed)
    #expect(store.connectionState == .disconnected)
    #expect(store.activeTicket == nil)
    #expect(store.connectionError?.contains("Tailscale") == true)
    // The loopback failure must name the fix (Tailscale), not fall through to
    // the generic invalid-code copy.
    #expect(store.connectionError != MobilePairingFailureCategory.invalidCode.message)
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
@Test func manualHostPairingRejectsDefaultPortLANHostWithoutSendingStackToken() async throws {
    // Same encrypted-routes-only contract as the explicit-port LAN test, on
    // the default host port: no RPC (and no Stack bearer token) may leave the
    // device for a plain-TCP private-LAN route.
    let responses = ScriptedTransportResponses([])
    let runtime = testRuntime(
        supportedRouteKinds: [.tailscale],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "stack-token-for-default-lan"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "Work Mac", host: "192.168.1.77", port: CmxMobileDefaults.defaultHostPort)

    #expect(store.phase == .pairing)
    #expect(store.connectionState == .disconnected)
    #expect(store.activeTicket == nil)
    #expect(store.activeRoute == nil)
    #expect(store.connectionError == "This pairing route is not allowed. Enter a host and port, or pair with a QR/link from that computer.")
    #expect(try await responses.sentRequests().isEmpty)
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
    #expect(store.selectedWorkspace?.id.rawValue == "local-workspace")
    #expect(store.selectedTerminalID?.rawValue == "local-terminal")
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
}

@MainActor
@Test func notReadySelectedTerminalDoesNotFallbackToReadyTerminalInAnotherWorkspace() async throws {
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
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectManualHost(name: "", host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)

    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.id.rawValue == "stale-workspace")
    #expect(store.selectedTerminalID?.rawValue == "stale-terminal")
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
    let router = RemoteCreateWorkspaceRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    store.createWorkspace()

    for _ in 0..<200 where store.selectedWorkspace?.id.rawValue != "workspace-3" {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(store.selectedWorkspace?.id.rawValue == "workspace-3")
    #expect(store.selectedTerminalID?.rawValue == "workspace-3-terminal-1")
    #expect(store.workspaces.map(\.id.rawValue) == ["workspace-main", "workspace-3"])
}

@MainActor
@Test func remoteCreateWorkspaceUsesAttachTicketAuth() async throws {
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
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        authToken: "ticket-secret"
    )
    let router = RemoteCreateWorkspaceRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        stackAccessToken: "test-stack-token"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    store.createWorkspace()

    for _ in 0..<200 where store.selectedWorkspace?.id.rawValue != "workspace-3" {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    let requests = await router.sentRequests()
    let createRequest = try #require(requests.first { $0.method == "workspace.create" })
    #expect(createRequest.attachToken == "ticket-secret")
    #expect(createRequest.stackAccessToken == "test-stack-token")
    #expect(store.connectionError == nil)
    #expect(store.workspaces.map(\.id.rawValue) == ["workspace-main", "workspace-3"])
    #expect(store.selectedWorkspace?.id.rawValue == "workspace-3")
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
@Test func remoteCreateTerminalKeepsOtherWorkspacesWhenMacReturnsScopedList() async throws {
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
    let router = RemoteCreateTerminalRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    #expect(store.workspaces.map(\.id.rawValue) == ["workspace-main", "workspace-docs"])

    store.createTerminal()

    for _ in 0..<200 where store.selectedTerminalID?.rawValue != "workspace-main-terminal-2" {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(store.workspaces.map(\.id.rawValue) == ["workspace-main", "workspace-docs"])
    #expect(store.selectedWorkspace?.id.rawValue == "workspace-main")
    #expect(store.selectedTerminalID?.rawValue == "workspace-main-terminal-2")
    #expect(store.workspaces.first { $0.id.rawValue == "workspace-docs" }?.terminals.first?.id.rawValue == "terminal-notes")
}

@MainActor
@Test func remoteCreateTerminalDoesNotStealSelectionAfterWorkspaceSwitch() async throws {
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
    let router = DelayedRemoteCreateTerminalRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    store.createTerminal()

    await router.waitForTerminalCreateRequest()
    await store.openWorkspace(.init(rawValue: "workspace-docs"))
    await router.releaseTerminalCreateResponse()

    for _ in 0..<200 where store.selectedTerminalID?.rawValue != "terminal-notes" {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    let requests = await router.sentRequests()
    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.id.rawValue == "workspace-docs")
    #expect(store.selectedTerminalID?.rawValue == "terminal-notes")
    #expect(!requests.contains { $0.workspaceID == "workspace-docs" && $0.terminalID == "workspace-main-terminal-2" })
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
@Test func submittedTerminalInputIncludesClientViewportAndCarriageReturn() async throws {
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
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: "live-workspace",
            title: "Live Workspace",
            terminalID: "live-terminal"
        ),
        try rpcResultFrame(result: ["accepted": true]),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.reportTerminalViewport(
        workspaceID: MobileWorkspacePreview.ID(rawValue: "live-workspace"),
        terminalID: MobileTerminalPreview.ID(rawValue: "live-terminal"),
        viewportSize: MobileTerminalViewportSize(columns: 52, rows: 24)
    )
    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    store.terminalInputText = "echo hi"
    await store.submitTerminalInput()

    let inputRequest = try #require(await responses.sentRequests().first { $0.method == "terminal.input" })
    #expect(inputRequest.text == "echo hi\r")
    #expect(inputRequest.viewportColumns == 52)
    #expect(inputRequest.viewportRows == 24)
    #expect(inputRequest.clientID?.isEmpty == false)
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
        try rpcResultFrame(result: ["accepted": true]),
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
@Test func terminalInputResyncsOutputWhenMacSequenceIsAhead() async throws {
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
    let router = TerminalOutputSelfHealingRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let collector = TerminalOutputCollector()

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    collector.mount(store: store, surfaceID: "live-terminal")
    let oldGridText = try terminalRenderGridReplacementText(seq: 4, text: "old")
    let currentGridText = try terminalRenderGridReplacementText(seq: 12, text: "current")

    _ = try await waitForRequestCount("mobile.terminal.replay", count: 1, router: router)

    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: "live-terminal")

    _ = try await waitForRequestCount("mobile.terminal.replay", count: 2, router: router)
    _ = try await waitForRequestCount("mobile.events.subscribe", count: 2, router: router)
    // The request-count waits only prove the second replay was REQUESTED; its
    // response still has to round-trip and deliver. The slower CI iPad leg
    // regularly needs more than the file's usual 200ms here.
    for _ in 0..<4000 where !collector.lines.contains(currentGridText) {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    #expect(collector.lines.last == currentGridText)
    #expect(Set(collector.lines).isSubset(of: [oldGridText, currentGridText]))
    #expect(collector.lines.count <= 2)
    collector.unmount()
}

@MainActor
@Test func renderGridTerminalInputWaitsForLiveEventBeforeReplay() async throws {
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
    let router = TerminalOutputSelfHealingRouter(renderGrid: true)
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let collector = TerminalOutputCollector()

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    _ = try await waitForRequestCount("mobile.events.subscribe", count: 1, router: router)
    collector.mount(store: store, surfaceID: "live-terminal")
    _ = try await waitForRequestCount("mobile.terminal.replay", count: 1, router: router)

    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: "live-terminal")
    let afterFirstInput = await router.sentRequests()
    #expect(afterFirstInput.filter { $0.method == "mobile.terminal.replay" }.count == 1)

    await store.submitTerminalRawInput(Data("y".utf8), surfaceID: "live-terminal")
    _ = try await waitForRequestCount("mobile.terminal.replay", count: 2, router: router)
    // The request-count wait only proves the second replay REQUEST was sent;
    // its response still flows back through the transport asynchronously.
    // Poll for delivery like the sibling tests do, then assert content.
    for _ in 0..<200 where collector.lines.count < 2 {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    let oldGridText = try terminalRenderGridReplacementText(seq: 4, text: "old")
    let currentGridText = try terminalRenderGridReplacementText(seq: 12, text: "current")
    #expect(collector.lines == [
        oldGridText,
        currentGridText,
    ])
    collector.unmount()
}

@MainActor
@Test func terminalRenderGridEventsDriveMountedSink() async throws {
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
    let router = TerminalRenderGridEventRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let collector = TerminalOutputCollector()

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)

    let subscribeRequests = try await waitForRequestCount("mobile.events.subscribe", count: 1, router: router)
    #expect(subscribeRequests.first?.topics == ["workspace.updated", "terminal.render_grid", "terminal.set_font", "notification.dismissed", "notification.badge"])

    collector.mount(store: store, surfaceID: "live-terminal")
    _ = try await waitForRequestCount("mobile.terminal.replay", count: 1, router: router)
    let liveText = try terminalRenderGridStyledReplacementText(seq: 2, text: "live")
    for _ in 0..<200 where !collector.lines.contains(liveText) {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    #expect(collector.lines.contains(liveText))
    #expect(collector.lines.last == liveText)
    #expect(liveText.contains("\u{1B}[0;1;4;38;2;255;0;0;48;2;0;0;255mlive"))
    #expect(liveText.contains("\u{1B}[6 q\u{1B}[?25h\u{1B}[2;3H"))
    collector.unmount()
}

@MainActor
@Test func coldTerminalAttachWaitsForReplayBeforePaintingLiveRenderGrid() async throws {
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
    let router = ColdAttachFirstPaintRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let collector = TerminalOutputCollector()

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    _ = try await waitForRequestCount("mobile.events.subscribe", count: 1, router: router)

    collector.mount(store: store, surfaceID: "live-terminal")
    _ = try await waitForRequestCount("mobile.terminal.replay", count: 1, router: router)

    // Same 10ms-slice, 3-second-ceiling cadence as waitForRequestCount, so the
    // first-paint wait has the explicit CI budget the shared helpers use.
    for _ in 0..<300 {
        guard collector.lines.isEmpty else { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    let initialText = try terminalRenderGridReplacementText(seq: 1, text: "initial")
    #expect(collector.lines.first == initialText)
    collector.unmount()
}

@MainActor
@Test func coldTerminalAttachReplayIncludesReportedViewport() async throws {
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
    let router = TerminalRenderGridEventRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let collector = TerminalOutputCollector()

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    let effectiveGrid = await store.updateTerminalViewport(
        surfaceID: "live-terminal",
        columns: 52,
        rows: 24
    )
    #expect(effectiveGrid?.columns == 52)
    #expect(effectiveGrid?.rows == 24)

    collector.mount(store: store, surfaceID: "live-terminal")
    let replayRequests = try await waitForRequestCount("mobile.terminal.replay", count: 1, router: router)
    let replayRequest = try #require(replayRequests.first)

    #expect(replayRequest.viewportColumns == 52)
    #expect(replayRequest.viewportRows == 24)
    #expect(replayRequest.clientID?.isEmpty == false)
    collector.unmount()
}

@MainActor
@Test func pullToRefreshAwaitsRealWorkspaceListRoundTrip() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "before-workspace",
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let router = PullToRefreshWorkspaceListRouter()
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    _ = try await waitForWorkspaceIDs(in: store, matching: ["before-workspace"])

    // A pull re-fetches `mobile.workspace.list` and only resolves once the
    // round-trip has applied the new authoritative list.
    await store.refreshWorkspaces()

    #expect(store.workspaces.map(\.id.rawValue) == ["after-workspace"])
    let refreshRequests = await router.sentRequests().filter { $0.method == "mobile.workspace.list" }
    #expect(refreshRequests.count == 1)
}

@MainActor
@Test func pullToRefreshWhileDisconnectedReturnsWithoutHangingOrClearingList() async throws {
    // Not connected: the pull must return promptly (no transport round-trip to
    // hang on) and leave the existing list intact.
    let store = MobileShellComposite.preview()
    let before = store.workspaces.map(\.id.rawValue)

    await store.refreshWorkspaces()

    #expect(store.connectionState == .disconnected)
    #expect(store.workspaces.map(\.id.rawValue) == before)
}

@MainActor
@Test func rapidPullToRefreshesCoalesceOntoOneRoundTrip() async throws {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "before-workspace",
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60)
    )
    let router = PullToRefreshWorkspaceListRouter(refreshResponseDelayNanoseconds: 50_000_000)
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        supportsServerPushEvents: true
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    _ = try await waitForWorkspaceIDs(in: store, matching: ["before-workspace"])

    // Two overlapping pulls (the second starts while the first is still in flight)
    // must coalesce onto a single `mobile.workspace.list` round-trip, not stack
    // two fetches.
    async let first: Void = store.refreshWorkspaces()
    async let second: Void = store.refreshWorkspaces()
    _ = await (first, second)

    #expect(store.workspaces.map(\.id.rawValue) == ["after-workspace"])
    let refreshRequests = await router.sentRequests().filter { $0.method == "mobile.workspace.list" }
    #expect(refreshRequests.count == 1)
}

private struct MissingTestStackAccessToken: Error {}

private struct TestIdentityProvider: MobileIdentityProviding {
    let currentUserIDValue: String?
    let currentUserEmailValue: String?

    @MainActor var currentUserID: String? { currentUserIDValue }
    @MainActor var currentUserEmail: String? { currentUserEmailValue }
}

private final class RecordingAnalytics: AnalyticsEmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue]) {}

    func setSuperProperties(_ properties: [String: AnalyticsValue]) {}

    func flush() async {}

    func eventCount(named name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0 == name }.count
    }
}

private func testRuntime(
    supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback, .websocket],
    transportFactory: any CmxByteTransportFactory,
    stackAccessToken: String? = "test-stack-token",
    rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
    pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
    now: @escaping @Sendable () -> Date = Date.init,
    supportsServerPushEvents: Bool = false
) -> CMUXMobileRuntime {
    // Tests script every response and assert on exact request order, so by
    // default they opt out of background subscribe/poll refreshes. New tests
    // that exercise the event path should pass `supportsServerPushEvents: true`.
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
        pairingRequestTimeoutNanoseconds: pairingRequestTimeoutNanoseconds,
        now: now,
        supportsServerPushEvents: supportsServerPushEvents
    )
}

private func attachURL(for ticket: CmxAttachTicket) throws -> URL {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = base64URLEncode(try encoder.encode(ticket.withCurrentMacPairingCompatibilityVersionForTest()))
    return try #require(URL(string: "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)"))
}

private extension CmxAttachTicket {
    func withCurrentMacPairingCompatibilityVersionForTest() throws -> CmxAttachTicket {
        guard macPairingCompatibilityVersion == nil else {
            return self
        }
        return try CmxAttachTicket(
            version: version,
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            macAppVersion: macAppVersion,
            macAppBuild: macAppBuild,
            routes: routes,
            expiresAt: expiresAt,
            authToken: authToken
        )
    }
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

private func waitForWorkspaceListRequestCount(
    _ count: Int,
    responses: ScriptedTransportResponses
) async throws -> [RecordedRPCRequest] {
    var workspaceLists: [RecordedRPCRequest] = []
    for _ in 0..<200 {
        workspaceLists = try await responses.sentRequests().filter { $0.method == "workspace.list" }
        if workspaceLists.count >= count {
            return workspaceLists
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return workspaceLists
}

private func waitForRequestCount(
    _ method: String,
    count: Int,
    router: any RequestAwareTransportRouter
) async throws -> [RecordedRPCRequest] {
    var matches: [RecordedRPCRequest] = []
    for _ in 0..<300 {
        matches = await router.sentRequests().filter { $0.method == method }
        if matches.count >= count {
            return matches
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return matches
}

@MainActor
private func waitForWorkspaceIDs(
    in store: CMUXMobileShellStore,
    matching expectedIDs: [String]
) async throws -> [String] {
    var workspaceIDs: [String] = []
    for _ in 0..<200 {
        workspaceIDs = store.workspaces.map(\.id.rawValue)
        if workspaceIDs == expectedIDs {
            return workspaceIDs
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return workspaceIDs
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

private func terminalRenderGridReplacementText(seq: UInt64, text: String) throws -> String {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "live-terminal",
        stateSeq: seq,
        columns: 16,
        rows: 4,
        text: text
    )
    return try #require(String(data: frame.vtReplacementBytes(), encoding: .utf8))
}

private func terminalRenderGridStyledReplacementText(seq: UInt64, text: String) throws -> String {
    let frame = try terminalRenderGridStyledFrame(seq: seq, text: text)
    return try #require(String(data: frame.vtReplacementBytes(), encoding: .utf8))
}

private func terminalRenderGridStyledFrame(seq: UInt64, text: String) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: "live-terminal",
        stateSeq: seq,
        columns: 16,
        rows: 4,
        cursor: .init(row: 1, column: 2, style: .bar),
        styles: [
            .init(id: 0, foreground: "#C0C0C0", background: "#101010"),
            .init(id: 1, foreground: "#FF0000", background: "#0000FF", bold: true, underline: true),
        ],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 1, text: text),
        ]
    )
}

private func rpcHostStatusFrame(
    renderGrid: Bool,
    terminalBytes: Bool = true,
    macDeviceID: String? = nil,
    macDisplayName: String? = nil
) throws -> Data {
    var capabilities = ["events.v1", "terminal.replay.v1"]
    if terminalBytes {
        capabilities.append("terminal.bytes.v1")
    }
    if renderGrid {
        capabilities.append("terminal.render_grid.v1")
    }
    var result: [String: Any] = [
        "terminal_fidelity": renderGrid ? "render_grid" : "ghostty_bytes",
        "capabilities": capabilities,
    ]
    if let macDeviceID {
        result["mac_device_id"] = macDeviceID
    }
    if let macDisplayName {
        result["mac_display_name"] = macDisplayName
    }
    return try rpcResultFrame(result: result)
}

private func terminalRenderGridEventFrame(
    seq: UInt64,
    text: String,
    styled: Bool = false,
    full: Bool = true,
    changedRows: Set<Int>? = nil
) throws -> Data {
    let frame = if styled {
        try terminalRenderGridStyledFrame(seq: seq, text: text)
    } else {
        try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "live-terminal",
            stateSeq: seq,
            columns: 16,
            rows: 4,
            text: text,
            full: full,
            changedRows: changedRows
        )
    }
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.render_grid",
        "payload": try frame.jsonObject(),
    ]
    let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
    return try MobileSyncFrameCodec.encodeFrame(envelopeData)
}

private func rpcTerminalReplayFrame(
    seq: UInt64,
    rawText: String,
    snapshotText: String? = nil,
    renderGridText: String? = nil,
    renderGridStyled: Bool = false
) throws -> Data {
    var result: [String: Any] = [
        "workspace_id": "live-workspace",
        "surface_id": "live-terminal",
        "seq": NSNumber(value: seq),
        "data_b64": Data(rawText.utf8).base64EncodedString(),
        "columns": 16,
        "rows": 4,
    ]
    if let snapshotText {
        result["snapshot_format"] = "ghostty.active.vt"
        result["snapshot_data_b64"] = Data(snapshotText.utf8).base64EncodedString()
    }
    if let renderGridText {
        let frame = if renderGridStyled {
            try terminalRenderGridStyledFrame(seq: seq, text: renderGridText)
        } else {
            try MobileTerminalRenderGridFrame.fromPlainRows(
                surfaceID: "live-terminal",
                stateSeq: seq,
                columns: 16,
                rows: 4,
                text: renderGridText
            )
        }
        result["render_grid"] = try frame.jsonObject()
    }
    return try rpcResultFrame(
        result: result
    )
}

private func rpcWorkspaceCreateFrame() throws -> Data {
    try rpcResultFrame(
        result: [
            "created_workspace_id": "workspace-3",
            "workspaces": [
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

private func rpcTwoWorkspaceListFrame() throws -> Data {
    try rpcResultFrame(
        result: [
            "workspaces": [
                [
                    "id": "workspace-main",
                    "title": "cmux",
                    "current_directory": "/Users/test/project",
                    "is_selected": true,
                    "terminals": [
                        [
                            "id": "terminal-build",
                            "title": "Build",
                            "current_directory": "/Users/test/project",
                            "is_ready": true,
                            "is_focused": true,
                        ],
                    ],
                ],
                [
                    "id": "workspace-docs",
                    "title": "Docs",
                    "current_directory": "/Users/test/docs",
                    "is_selected": false,
                    "terminals": [
                        [
                            "id": "terminal-notes",
                            "title": "Notes",
                            "current_directory": "/Users/test/docs",
                            "is_ready": true,
                            "is_focused": true,
                        ],
                    ],
                ],
            ],
        ]
    )
}

private func rpcTerminalCreateScopedFrame() throws -> Data {
    try rpcResultFrame(
        result: [
            "created_terminal_id": "workspace-main-terminal-2",
            "workspaces": [
                [
                    "id": "workspace-main",
                    "title": "cmux",
                    "current_directory": "/Users/test/project",
                    "is_selected": true,
                    "terminals": [
                        [
                            "id": "terminal-build",
                            "title": "Build",
                            "current_directory": "/Users/test/project",
                            "is_ready": true,
                            "is_focused": false,
                        ],
                        [
                            "id": "workspace-main-terminal-2",
                            "title": "Terminal 2",
                            "current_directory": "/Users/test/project",
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
        macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
        routes: [route],
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
        authToken: "ticket-secret"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let ticketObject = try JSONSerialization.jsonObject(with: encoder.encode(ticket))
    return try rpcResultFrame(result: ["ticket": ticketObject])
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

private struct ScriptedTransportFactory: CmxByteTransportFactory {
    let responses: ScriptedTransportResponses

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        ScriptedTransport(responses: responses)
    }
}

private struct FailingRouteTransportFactory: CmxByteTransportFactory {
    let failingRouteID: String
    let responses: ScriptedTransportResponses
    let attempts: RouteAttemptRecorder

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        FailingRouteTransport(
            routeID: route.id,
            failingRouteID: failingRouteID,
            responses: responses,
            attempts: attempts
        )
    }
}

private protocol RequestAwareTransportRouter: Actor {
    func record(_ request: RecordedRPCRequest)
    func sentRequests() -> [RecordedRPCRequest]
    func response(for request: RecordedRPCRequest) async throws -> Data?
}

private struct RequestAwareTransportFactory: CmxByteTransportFactory {
    let router: any RequestAwareTransportRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        RequestAwareTransport(router: router)
    }
}

private actor DelayedManualAttachTicketRouter: RequestAwareTransportRouter {
    private let route: CmxAttachRoute
    private var attachTicketRequested = false
    private var attachTicketReleased = false
    private var attachTicketRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var attachTicketReleaseContinuation: CheckedContinuation<Void, Never>?
    private var requests: [RecordedRPCRequest] = []

    init(route: CmxAttachRoute) {
        self.route = route
    }

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func waitForAttachTicketRequest() async {
        guard !attachTicketRequested else { return }
        await withCheckedContinuation { continuation in
            attachTicketRequestWaiters.append(continuation)
        }
    }

    func releaseAttachTicketResponse() {
        attachTicketReleased = true
        attachTicketReleaseContinuation?.resume()
        attachTicketReleaseContinuation = nil
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "mobile.attach_ticket.create":
            markAttachTicketRequested()
            await waitForAttachTicketRelease()
            return try rpcAttachTicketFrame(route: route, workspaceID: "delayed-workspace")
        case "workspace.list":
            return try rpcWorkspaceListFrame(workspaceID: "delayed-workspace", title: "Delayed Workspace")
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }

    private func markAttachTicketRequested() {
        attachTicketRequested = true
        let waiters = attachTicketRequestWaiters
        attachTicketRequestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForAttachTicketRelease() async {
        guard !attachTicketReleased else { return }
        await withCheckedContinuation { continuation in
            attachTicketReleaseContinuation = continuation
        }
    }
}

private actor SupersededAttachURLRouter: RequestAwareTransportRouter {
    private var workspaceListRequestCount = 0
    private var firstWorkspaceListRequested = false
    private var firstWorkspaceListReleased = false
    private var firstWorkspaceListRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWorkspaceListReleaseContinuation: CheckedContinuation<Void, Never>?
    private var requests: [RecordedRPCRequest] = []

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func waitForFirstWorkspaceListRequest() async {
        guard !firstWorkspaceListRequested else { return }
        await withCheckedContinuation { continuation in
            firstWorkspaceListRequestWaiters.append(continuation)
        }
    }

    func releaseFirstWorkspaceListResponse() {
        firstWorkspaceListReleased = true
        firstWorkspaceListReleaseContinuation?.resume()
        firstWorkspaceListReleaseContinuation = nil
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            workspaceListRequestCount += 1
            if workspaceListRequestCount == 1 {
                markFirstWorkspaceListRequested()
                await waitForFirstWorkspaceListRelease()
                return try rpcWorkspaceListFrame(
                    workspaceID: "first-workspace",
                    title: "First Workspace",
                    terminalID: "first-terminal"
                )
            }
            return try rpcWorkspaceListFrame(
                workspaceID: "second-workspace",
                title: "Second Workspace",
                terminalID: "second-terminal"
            )
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }

    private func markFirstWorkspaceListRequested() {
        firstWorkspaceListRequested = true
        let waiters = firstWorkspaceListRequestWaiters
        firstWorkspaceListRequestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForFirstWorkspaceListRelease() async {
        guard !firstWorkspaceListReleased else { return }
        await withCheckedContinuation { continuation in
            firstWorkspaceListReleaseContinuation = continuation
        }
    }
}

private actor RemoteCreateTerminalRouter: RequestAwareTransportRouter {
    private var requests: [RecordedRPCRequest] = []

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcTwoWorkspaceListFrame()
        case "terminal.create":
            return try rpcTerminalCreateScopedFrame()
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

private actor DelayedRemoteCreateTerminalRouter: RequestAwareTransportRouter {
    private var terminalCreateRequested = false
    private var terminalCreateReleased = false
    private var terminalCreateRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalCreateReleaseContinuation: CheckedContinuation<Void, Never>?
    private var requests: [RecordedRPCRequest] = []

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func waitForTerminalCreateRequest() async {
        guard !terminalCreateRequested else { return }
        await withCheckedContinuation { continuation in
            terminalCreateRequestWaiters.append(continuation)
        }
    }

    func releaseTerminalCreateResponse() {
        terminalCreateReleased = true
        terminalCreateReleaseContinuation?.resume()
        terminalCreateReleaseContinuation = nil
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcTwoWorkspaceListFrame()
        case "terminal.create":
            markTerminalCreateRequested()
            await waitForTerminalCreateRelease()
            return try rpcTerminalCreateScopedFrame()
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }

    private func markTerminalCreateRequested() {
        terminalCreateRequested = true
        let waiters = terminalCreateRequestWaiters
        terminalCreateRequestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForTerminalCreateRelease() async {
        guard !terminalCreateReleased else { return }
        await withCheckedContinuation { continuation in
            terminalCreateReleaseContinuation = continuation
        }
    }
}

private actor RemoteCreateWorkspaceRouter: RequestAwareTransportRouter {
    private var requests: [RecordedRPCRequest] = []

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcWorkspaceListFrame(
                workspaceID: "workspace-main",
                title: "cmux",
                terminalID: "terminal-build"
            )
        case "workspace.create":
            return try rpcWorkspaceCreateFrame()
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

private actor TerminalOutputSelfHealingRouter: RequestAwareTransportRouter {
    private let renderGrid: Bool
    private var requests: [RecordedRPCRequest] = []
    private var replayCount = 0

    init(renderGrid: Bool = false) {
        self.renderGrid = renderGrid
    }

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcWorkspaceListFrame(
                workspaceID: "live-workspace",
                title: "Live Workspace",
                terminalID: "live-terminal"
            )
        case "mobile.host.status":
            return try rpcHostStatusFrame(renderGrid: renderGrid)
        case "mobile.events.subscribe":
            return try rpcResultFrame(result: ["stream_id": "events"])
        case "mobile.terminal.replay":
            replayCount += 1
            if replayCount == 1 {
                return try rpcTerminalReplayFrame(
                    seq: 4,
                    rawText: "stale-old-tail",
                    snapshotText: "old",
                    renderGridText: "old"
                )
            }
            return try rpcTerminalReplayFrame(
                seq: 12,
                rawText: "stale-current-tail",
                snapshotText: "current",
                renderGridText: "current"
            )
        case "terminal.input":
            return try rpcResultFrame(
                result: [
                    "workspace_id": "live-workspace",
                    "surface_id": "live-terminal",
                    "queued": false,
                    "terminal_seq": 12,
                ]
            )
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

private actor TerminalRenderGridEventRouter: RequestAwareTransportRouter {
    private var requests: [RecordedRPCRequest] = []
    private var replayRequestCount = 0

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcWorkspaceListFrame(
                workspaceID: "live-workspace",
                title: "Live Workspace",
                terminalID: "live-terminal"
            )
        case "mobile.host.status":
            return try rpcHostStatusFrame(renderGrid: true, terminalBytes: false)
        case "mobile.events.subscribe":
            return try rpcResultFrame(result: ["stream_id": "events"])
        case "mobile.terminal.viewport":
            return try rpcResultFrame(result: [
                "columns": request.viewportColumns ?? 80,
                "rows": request.viewportRows ?? 24,
            ])
        case "mobile.terminal.replay":
            replayRequestCount += 1
            if replayRequestCount == 1 {
                return try combinedFrames([
                    rpcTerminalReplayFrame(
                        seq: 1,
                        rawText: "unused-tail",
                        renderGridText: "initial"
                    ),
                    terminalRenderGridEventFrame(seq: 2, text: "live", styled: true),
                ])
            }
            // The live event races the cold-attach replay barrier: when it
            // lands inside the barrier window it is dropped and recovered by
            // the follow-up catch-up replay instead. An honest host serves
            // its LATEST grid on that follow-up, so this router must too —
            // re-serving the stale seq-1 base would model a host that never
            // converges.
            return try rpcTerminalReplayFrame(
                seq: 2,
                rawText: "unused-tail",
                renderGridText: "live",
                renderGridStyled: true
            )
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

private actor ColdAttachFirstPaintRouter: RequestAwareTransportRouter {
    private var requests: [RecordedRPCRequest] = []
    private var replayCount = 0

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcWorkspaceListFrame(
                workspaceID: "live-workspace",
                title: "Live Workspace",
                terminalID: "live-terminal"
            )
        case "mobile.host.status":
            return try rpcHostStatusFrame(renderGrid: true, terminalBytes: false)
        case "mobile.events.subscribe":
            return try rpcResultFrame(result: ["stream_id": "events"])
        case "mobile.terminal.replay":
            replayCount += 1
            if replayCount == 1 {
                return try combinedFrames([
                    terminalRenderGridEventFrame(
                        seq: 2,
                        text: "stray",
                        full: false,
                        changedRows: [1]
                    ),
                    rpcTerminalReplayFrame(
                        seq: 1,
                        rawText: "unused-tail",
                        renderGridText: "initial"
                    ),
                ])
            }
            return try rpcTerminalReplayFrame(
                seq: 3,
                rawText: "unused-tail",
                renderGridText: "settled"
            )
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

/// Router for the pull-to-refresh tests: the connect-time `workspace.list`
/// returns `before-workspace`; the pull-driven `mobile.workspace.list` returns a
/// different `after-workspace`, so the test can prove the pull re-fetched and
/// applied authoritative data. An optional response delay lets a second
/// overlapping pull start while the first is still in flight, exercising the
/// in-flight coalescing guard.
private actor PullToRefreshWorkspaceListRouter: RequestAwareTransportRouter {
    private let refreshResponseDelayNanoseconds: UInt64
    private var requests: [RecordedRPCRequest] = []

    init(refreshResponseDelayNanoseconds: UInt64 = 0) {
        self.refreshResponseDelayNanoseconds = refreshResponseDelayNanoseconds
    }

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcWorkspaceListFrame(workspaceID: "before-workspace", title: "Before Workspace")
        case "mobile.workspace.list":
            if refreshResponseDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: refreshResponseDelayNanoseconds)
            }
            return try rpcWorkspaceListFrame(workspaceID: "after-workspace", title: "After Workspace")
        case "mobile.host.status":
            return try rpcHostStatusFrame(renderGrid: true)
        case "mobile.events.subscribe":
            return try rpcResultFrame(result: ["stream_id": "events"])
        case "mobile.terminal.replay":
            return try rpcResultFrame(result: [:])
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

private actor RequestAwareTransport: CmxByteTransport {
    private let router: any RequestAwareTransportRouter
    private var pendingResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: any RequestAwareTransportRouter) {
        self.router = router
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingResponses.isEmpty {
            return pendingResponses.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let request = try recordedRPCRequest(from: payload)
            await router.record(request)
            // Process each request concurrently so a router that blocks one
            // request (e.g. a delayed terminal.create) doesn't head-of-line
            // block subsequent RPCs the persistent transport sends. Matches
            // the Mac-side semantics we'd want once respond() goes
            // concurrent on a single connection.
            Task { [router, weak self] in
                guard let response = try? await router.response(for: request) else {
                    return
                }
                guard let stamped = try? responseFrame(response, matching: request) else {
                    return
                }
                await self?.deliver(stamped)
            }
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func deliver(_ response: Data) {
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume(returning: response)
        } else {
            pendingResponses.append(response)
        }
    }
}

private actor RouteAttemptRecorder {
    private var recordedRouteIDs: [String] = []

    func record(_ routeID: String) {
        recordedRouteIDs.append(routeID)
    }

    func routeIDs() -> [String] {
        recordedRouteIDs
    }
}

private actor ScriptedTransportResponses {
    private var frames: [Data]
    private var sentPayloads: [Data] = []

    init(_ frames: [Data]) {
        self.frames = frames
    }

    func recordSend(_ data: Data) throws -> [Data] {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        var responses: [Data] = []
        for payload in payloads {
            sentPayloads.append(payload)
            guard !frames.isEmpty else {
                continue
            }
            let request = try recordedRPCRequest(from: payload)
            let response = try responseFrame(frames.removeFirst(), matching: request)
            responses.append(response)
        }
        return responses
    }

    func hasRemainingFrames() -> Bool {
        !frames.isEmpty
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map { payload in
            let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let params = request["params"] as? [String: Any] ?? [:]
            let auth = request["auth"] as? [String: Any]
            return RecordedRPCRequest(
                id: request["id"] as? String,
                method: request["method"] as? String,
                workspaceID: params["workspace_id"] as? String,
                terminalID: params["terminal_id"] as? String ??
                    params["surface_id"] as? String ??
                    params["tab_id"] as? String,
                viewportColumns: params["viewport_columns"] as? Int,
                viewportRows: params["viewport_rows"] as? Int,
                maxScrollbackRows: params["max_scrollback_rows"] as? Int,
                clientID: params["client_id"] as? String,
                text: params["text"] as? String,
                topics: params["topics"] as? [String],
                hasAuth: auth != nil,
                attachToken: auth?["attach_token"] as? String,
                stackAccessToken: auth?["stack_access_token"] as? String
            )
        }
    }
}

private struct RecordedRPCRequest: Sendable {
    var id: String?
    var method: String?
    var workspaceID: String?
    var terminalID: String?
    var viewportColumns: Int?
    var viewportRows: Int?
    var maxScrollbackRows: Int?
    var clientID: String?
    var text: String?
    var topics: [String]?
    var hasAuth: Bool
    var attachToken: String?
    var stackAccessToken: String?
}

private func recordedRPCRequest(from payload: Data) throws -> RecordedRPCRequest {
    let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let params = request["params"] as? [String: Any] ?? [:]
    let auth = request["auth"] as? [String: Any]
    return RecordedRPCRequest(
        id: request["id"] as? String,
        method: request["method"] as? String,
        workspaceID: params["workspace_id"] as? String,
        terminalID: params["terminal_id"] as? String ?? params["surface_id"] as? String,
        viewportColumns: params["viewport_columns"] as? Int,
        viewportRows: params["viewport_rows"] as? Int,
        maxScrollbackRows: params["max_scrollback_rows"] as? Int,
        clientID: params["client_id"] as? String,
        text: params["text"] as? String,
        topics: params["topics"] as? [String],
        hasAuth: auth != nil,
        attachToken: auth?["attach_token"] as? String,
        stackAccessToken: auth?["stack_access_token"] as? String
    )
}

private actor ScriptedTransport: CmxByteTransport {
    private let responses: ScriptedTransportResponses
    private var pendingResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var inFlightSends = 0
    private var isClosed = false

    init(responses: ScriptedTransportResponses) {
        self.responses = responses
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        await nextResponse()
    }

    func send(_ data: Data) async throws {
        inFlightSends += 1
        let responseFrames: [Data]
        do {
            responseFrames = try await responses.recordSend(data)
        } catch {
            inFlightSends -= 1
            await finishExhaustedReceiversIfIdle()
            throw error
        }
        for frame in responseFrames {
            enqueue(frame)
        }
        inFlightSends -= 1
        await finishExhaustedReceiversIfIdle()
    }

    func close() async {
        closeLocal()
    }

    private func nextResponse() async -> Data? {
        if !pendingResponses.isEmpty {
            return pendingResponses.removeFirst()
        }
        if isClosed {
            return nil
        }
        if inFlightSends > 0 {
            return await waitForResponse()
        }
        guard await responses.hasRemainingFrames() else {
            return nil
        }
        return await waitForResponse()
    }

    private func waitForResponse() async -> Data? {
        await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    private func enqueue(_ response: Data) {
        if receiveWaiters.isEmpty {
            pendingResponses.append(response)
        } else {
            let waiter = receiveWaiters.removeFirst()
            waiter.resume(returning: response)
        }
    }

    private func finishExhaustedReceiversIfIdle() async {
        guard inFlightSends == 0, pendingResponses.isEmpty, !(await responses.hasRemainingFrames()) else {
            return
        }
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func closeLocal() {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

private enum FailingRouteTransportError: Error {
    case connectFailed
}

private actor FailingRouteTransport: CmxByteTransport {
    private let routeID: String
    private let failingRouteID: String
    private let responses: ScriptedTransportResponses
    private let attempts: RouteAttemptRecorder
    private var pendingResponses: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var inFlightSends = 0
    private var isClosed = false

    init(
        routeID: String,
        failingRouteID: String,
        responses: ScriptedTransportResponses,
        attempts: RouteAttemptRecorder
    ) {
        self.routeID = routeID
        self.failingRouteID = failingRouteID
        self.responses = responses
        self.attempts = attempts
    }

    func connect() async throws {
        await attempts.record(routeID)
        if routeID == failingRouteID {
            throw FailingRouteTransportError.connectFailed
        }
    }

    func receive() async throws -> Data? {
        await nextResponse()
    }

    func send(_ data: Data) async throws {
        inFlightSends += 1
        let responseFrames: [Data]
        do {
            responseFrames = try await responses.recordSend(data)
        } catch {
            inFlightSends -= 1
            await finishExhaustedReceiversIfIdle()
            throw error
        }
        for frame in responseFrames {
            enqueue(frame)
        }
        inFlightSends -= 1
        await finishExhaustedReceiversIfIdle()
    }

    func close() async {
        closeLocal()
    }

    private func nextResponse() async -> Data? {
        if !pendingResponses.isEmpty {
            return pendingResponses.removeFirst()
        }
        if isClosed {
            return nil
        }
        if inFlightSends > 0 {
            return await waitForResponse()
        }
        guard await responses.hasRemainingFrames() else {
            return nil
        }
        return await waitForResponse()
    }

    private func waitForResponse() async -> Data? {
        await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    private func enqueue(_ response: Data) {
        if receiveWaiters.isEmpty {
            pendingResponses.append(response)
        } else {
            let waiter = receiveWaiters.removeFirst()
            waiter.resume(returning: response)
        }
    }

    private func finishExhaustedReceiversIfIdle() async {
        guard inFlightSends == 0, pendingResponses.isEmpty, !(await responses.hasRemainingFrames()) else {
            return
        }
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func closeLocal() {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

private func responseFrame(_ data: Data, matching request: RecordedRPCRequest) throws -> Data {
    guard let requestID = request.id else {
        return data
    }
    var buffer = data
    let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
    guard !frames.isEmpty else {
        return data
    }
    var encoded = Data()
    for frame in frames {
        guard var envelope = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
            encoded.append(try MobileSyncFrameCodec.encodeFrame(frame))
            continue
        }
        envelope["id"] = requestID
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        encoded.append(try MobileSyncFrameCodec.encodeFrame(envelopeData))
    }
    return encoded
}

private func combinedFrames(_ frames: [Data]) -> Data {
    frames.reduce(into: Data()) { output, frame in
        output.append(frame)
    }
}

private struct HangingTransportFactory: CmxByteTransportFactory {
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        HangingTransport()
    }
}

/// A ``ReachabilityProviding`` double reporting a permanently-offline device, so
/// the pairing reachability preflight short-circuits before any connect.
private struct OfflineReachability: ReachabilityProviding {
    var isOnline: Bool { false }
    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// Counts how many times a transport was created (dialed), synchronously, so
/// the "zero transports created" assertion cannot race a fire-and-forget task.
/// Used to prove the offline preflight returns before any transport is made.
private final class TransportDialRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var dialCount = 0
    var count: Int {
        lock.withLock { dialCount }
    }

    func record() {
        lock.withLock { dialCount += 1 }
    }
}

/// A transport factory whose product would never connect; it records each
/// `makeTransport` synchronously so a test can assert the offline preflight
/// never dialed.
private struct RecordingNeverConnectTransportFactory: CmxByteTransportFactory {
    let dials: TransportDialRecorder
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        dials.record()
        return HangingTransport()
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

private func rpcErrorFrame(code: String? = nil, message: String) throws -> Data {
    var error: [String: Any] = [
        "message": message,
    ]
    if let code {
        error["code"] = code
    }
    let envelope: [String: Any] = [
        "id": UUID().uuidString,
        "ok": false,
        "error": error,
    ]
    let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
    return try MobileSyncFrameCodec.encodeFrame(envelopeData)
}

// MARK: - Push notification deep-link

/// Inert registration stub: deep-link tests exercise tap routing only.
private struct InertPushRegistration: PushRegistering {
    var isEnabled: Bool {
        get async { false }
    }
    func setEnabled(_ enabled: Bool) async {}
    func register(deviceToken: Data) async {}
    func syncTokenIfPossible() async {}
    func unregisterFromServer() async {}
    func unregisterFromServer(accessToken: String?, refreshToken: String?) async {}
}

@MainActor private func deeplinkTestStore() -> CMUXMobileShellStore {
    CMUXMobileShellStore(
        runtime: testRuntime(
            transportFactory: RecordingNeverConnectTransportFactory(dials: TransportDialRecorder())
        ),
        reachability: OfflineReachability()
    )
}

/// Cold launch from a notification tap: `didReceive` fires before the root
/// view has mounted, so no store is bound yet. The tap must survive until the
/// store binds and its workspace list loads, then navigate. Pre-fix the tap
/// was dropped (`reason: no_store`) and the user landed on the workspaces
/// home screen.
@Test @MainActor func notificationTapBeforeStoreBindsNavigatesOnceWorkspacesLoad() async throws {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())

    // Tap arrives first: nothing is bound.
    coordinator.handleTap(workspaceId: "workspace-docs", surfaceId: "terminal-notes")

    // Root view mounts: store binds already carrying the attached list.
    let store = deeplinkTestStore()
    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.bind(store: store)

    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-docs"))
    #expect(store.selectedTerminalID == MobileTerminalPreview.ID(rawValue: "terminal-notes"))
}

/// Tap lands while the store is bound but the Mac attach has not delivered
/// the workspace list yet: the deep link applies when the list fills in,
/// driven by the root view's workspace-list change hook.
@Test @MainActor func notificationTapBeforeAttachAppliesWhenWorkspaceArrives() async throws {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    coordinator.bind(store: store)

    coordinator.handleTap(workspaceId: "workspace-docs", surfaceId: "terminal-notes")
    // Target not loaded yet: no navigation to an absent workspace.
    #expect(store.selectedWorkspaceID == nil)

    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.workspacesDidChange()

    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-docs"))
    #expect(store.selectedTerminalID == MobileTerminalPreview.ID(rawValue: "terminal-notes"))
}

/// A parked tap expires: navigating minutes later would yank the user out of
/// whatever they moved on to.
@Test @MainActor func notificationTapExpiresInsteadOfNavigatingLate() async throws {
    nonisolated(unsafe) var currentTime = Date(timeIntervalSince1970: 1_000_000)
    let coordinator = MobilePushCoordinator(
        registration: InertPushRegistration(),
        now: { currentTime }
    )
    coordinator.handleTap(workspaceId: "workspace-docs", surfaceId: "terminal-notes")

    currentTime = currentTime.addingTimeInterval(121)
    let store = deeplinkTestStore()
    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.bind(store: store)

    #expect(store.selectedWorkspaceID == nil)
    #expect(store.selectedTerminalID == nil)
}

/// A surface-only tap (no workspaceId in the payload) must wait for the
/// terminal's owning workspace to load, then navigate to that workspace and
/// select the terminal. Pre-fix it bypassed the membership gate: the terminal
/// was selected against an empty store and the tap was discarded with no
/// retry, stranding the user on the home screen.
@Test @MainActor func surfaceOnlyNotificationTapWaitsForOwningWorkspace() async throws {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    coordinator.bind(store: store)

    coordinator.handleTap(workspaceId: nil, surfaceId: "terminal-notes")
    // Nothing loaded yet: the tap must stay parked, not be spent.
    #expect(store.selectedTerminalID == nil)

    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.workspacesDidChange()

    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-docs"))
    #expect(store.selectedTerminalID == MobileTerminalPreview.ID(rawValue: "terminal-notes"))
}

/// The workspace snapshot can arrive before its terminal list fills in. The
/// tap lands the user in the right workspace immediately and keeps the
/// terminal part parked, selecting it when its snapshot arrives instead of
/// pointing the store at a non-existent surface.
@Test @MainActor func notificationTapKeepsTerminalParkedUntilItsSnapshotArrives() async throws {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    coordinator.bind(store: store)

    coordinator.handleTap(workspaceId: "workspace-docs", surfaceId: "terminal-notes")
    store.replaceForegroundWorkspaceState([
        MobileWorkspacePreview(id: "workspace-docs", name: "Docs", terminals: [])
    ])
    coordinator.workspacesDidChange()

    // Workspace navigation happens now; the absent terminal is not selected.
    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-docs"))
    #expect(store.selectedTerminalID == nil)

    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.workspacesDidChange()

    #expect(store.selectedTerminalID == MobileTerminalPreview.ID(rawValue: "terminal-notes"))
}

/// A resolved tap must emit the one-shot navigation intent the compact
/// (iPhone) shell consumes to push its `NavigationStack`: selection alone
/// leaves an empty path untouched by design, which is what stranded
/// cold-launch taps on the workspaces home screen.
@Test @MainActor func notificationTapEmitsConsumableCompactNavigationIntent() async throws {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.bind(store: store)

    coordinator.handleTap(workspaceId: "workspace-docs", surfaceId: nil)

    let target = MobileWorkspacePreview.ID(rawValue: "workspace-docs")
    #expect(store.deeplinkWorkspaceNavigationRequest?.workspaceID == target)
    #expect(store.consumeDeeplinkWorkspaceNavigationRequest() == target)
    // One-shot: a later layout remount cannot replay a stale push.
    #expect(store.deeplinkWorkspaceNavigationRequest == nil)
    #expect(store.consumeDeeplinkWorkspaceNavigationRequest() == nil)
}
