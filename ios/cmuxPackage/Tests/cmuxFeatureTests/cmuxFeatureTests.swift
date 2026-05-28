import CMUXMobileCore
import Foundation
import StackAuth
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import cmuxFeature

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

@Test func authAutoLoginPolicyUsesRealStoredTokenState() {
    let credentials = AuthAutoLoginCredentials(email: "test@example.com", password: "pass")

    #expect(MobileAuthAutoLoginPolicy.shouldStartAutoLogin(credentials: credentials, hasStoredTokens: false))
    #expect(!MobileAuthAutoLoginPolicy.shouldStartAutoLogin(credentials: credentials, hasStoredTokens: true))
    #expect(!MobileAuthAutoLoginPolicy.shouldStartAutoLogin(credentials: nil, hasStoredTokens: false))
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

@Test func signInCodeInputPolicyNormalizesPastedCodesBeforeVerifying() {
    #expect(SignInCodeInputPolicy.action(for: "12345") == .none)
    #expect(SignInCodeInputPolicy.action(for: "123456") == .verify)
    #expect(SignInCodeInputPolicy.action(for: "123456\n") == .assign("123456"))
    #expect(SignInCodeInputPolicy.action(for: "1234567") == .assign("123456"))
}

@Test func authDisplaySafeErrorPreservesUserFacingStackErrors() throws {
    let userFacingCodes = [
        "SCHEMA_ERROR",
        "USER_EMAIL_ALREADY_EXISTS",
        "VERIFICATION_CODE_ERROR",
        "INVALID_OTP",
        "OTP_EXPIRED",
        "RATE_LIMIT",
        "EMAIL_PASSWORD_MISMATCH",
        "USER_NOT_FOUND",
        "PASSKEY_AUTHENTICATION_FAILED",
        "PASSKEY_WEBAUTHN_ERROR",
        "INVALID_TOTP_CODE",
        "REDIRECT_URL_NOT_WHITELISTED",
        "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN",
        "INVALID_APPLE_CREDENTIALS",
    ]

    for code in userFacingCodes {
        let mapped = AuthManager.displaySafeAuthError(StackAuthError(code: code, message: "message"))
        let stackError = try #require(mapped as? StackAuthErrorProtocol)
        #expect(stackError.code == code)
    }
}

@Test func authDisplaySafeErrorMapsCancellationAndUnknownStackErrors() throws {
    let cancelled = AuthManager.displaySafeAuthError(StackAuthError(code: "oauth_cancelled", message: "cancelled"))
    guard case AuthError.cancelled = cancelled else {
        Issue.record("Expected OAuth cancellation to map to AuthError.cancelled")
        return
    }

    let unknown = AuthManager.displaySafeAuthError(StackAuthError(code: "UNEXPECTED", message: "raw server detail"))
    guard case AuthError.serverError(0, "auth_failed") = unknown else {
        Issue.record("Expected unknown Stack errors to use the generic auth failure")
        return
    }
}

@Test func cachedSessionValidationClearsOnlyDefinitiveUnauthorizedFailures() {
    #expect(
        AuthManager.cachedSessionValidationFailureAction(
            for: StackAuthError(code: "UNAUTHORIZED", message: "expired")
        ) == .clearSession
    )
    #expect(
        AuthManager.cachedSessionValidationFailureAction(
            for: StackAuthError(code: "INVALID_TOKEN", message: "invalid")
        ) == .clearSession
    )
    #expect(
        AuthManager.cachedSessionValidationFailureAction(
            for: URLError(.notConnectedToInternet)
        ) == .preserveCachedSession
    )
    #expect(
        AuthManager.cachedSessionValidationFailureAction(
            for: StackAuthError(code: "RATE_LIMIT", message: "try later")
        ) == .preserveCachedSession
    )
}

@Test func rpcRequestTimeoutCancelsOperationWhenCallerIsCancelled() async throws {
    let started = AsyncFlag()
    let cancelled = AsyncFlag()
    let task = Task {
        try await MobileCoreRPCClient.debugWithRequestTimeout(
            timeoutNanoseconds: 60 * 1_000_000_000
        ) {
            await started.set()
            do {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                return "completed"
            } catch {
                await cancelled.set()
                throw error
            }
        }
    }

    for _ in 0..<100 {
        if await started.isSet() {
            break
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await started.isSet())

    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected cancelled RPC timeout wrapper to throw")
    } catch is CancellationError {
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
    }

    for _ in 0..<100 {
        if await cancelled.isSet() {
            break
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await cancelled.isSet())
}

@Test func cancelledQueuedRPCIsNotWrittenAfterEarlierSendCompletes() async throws {
    let transport = QueuedCancellationProbeTransport()
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 59123)
    let runtime = testRuntime(
        transportFactory: QueuedCancellationProbeTransportFactory(transport: transport),
        rpcRequestTimeoutNanoseconds: 60 * 1_000_000_000
    )
    let ticket = try CmxAttachTicket(
        workspaceID: "workspace-main",
        terminalID: "terminal-main",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let client = MobileCoreRPCClient(runtime: runtime, route: route, ticket: ticket)
    let firstRequest = try MobileCoreRPCClient.requestData(
        method: "terminal.input",
        params: [
            "workspace_id": "workspace-main",
            "terminal_id": "terminal-main",
            "text": "first",
        ],
        id: "first-input"
    )
    let queuedRequest = try MobileCoreRPCClient.requestData(
        method: "workspace.create",
        params: ["title": "queued-workspace"],
        id: "queued-create"
    )

    let firstTask = Task {
        try await client.sendRequest(firstRequest)
    }
    let firstSent = try await transport.waitForSentRequestCount(1)
    #expect(firstSent.map(\.method) == ["terminal.input"])

    let queuedTask = Task {
        try await client.sendRequest(queuedRequest)
    }
    for _ in 0..<100 {
        await Task.yield()
    }
    queuedTask.cancel()
    do {
        _ = try await queuedTask.value
        Issue.record("Expected queued RPC cancellation to throw")
    } catch {
    }

    await transport.releaseFirstSend()
    for _ in 0..<100 {
        if try await transport.sentRequests().count > 1 {
            break
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    let sent = try await transport.sentRequests()
    #expect(sent.map(\.method) == ["terminal.input"])
    firstTask.cancel()
    _ = try? await firstTask.value
}

@Test func mobileRuntimeDefaultsToThirtySecondRPCTimeout() {
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: ScriptedTransportResponses([])),
        stackAccessTokenProvider: { "test-stack-token" }
    )

    #expect(runtime.rpcRequestTimeoutNanoseconds == 30 * 1_000_000_000)
    #expect(runtime.pairingRequestTimeoutNanoseconds == 8 * 1_000_000_000)
}

@Test func manualRouteAuthPolicyAllowsStackAuthOnlyForTrustedManualHostPortRoutes() throws {
    let loopback = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let tailscaleIP = try hostPortRoute(kind: .tailscale, host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
    let lanIP = try hostPortRoute(kind: .tailscale, host: "192.168.1.77", port: CmxMobileDefaults.defaultHostPort)
    let localDNS = try hostPortRoute(kind: .tailscale, host: "devbox.local", port: CmxMobileDefaults.defaultHostPort)
    let tailscaleMagicDNS = try hostPortRoute(kind: .tailscale, host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)
    let pretendLoopback = try hostPortRoute(kind: .debugLoopback, host: "127.attacker.example", port: CmxMobileDefaults.defaultHostPort)

    #expect(MobileShellRouteAuthPolicy.manualRouteKind(for: "127.0.0.1") == .debugLoopback)
    #expect(MobileShellRouteAuthPolicy.manualRouteKind(for: "127.attacker.example") == .tailscale)
    #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(loopback))
    #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(tailscaleMagicDNS))
    #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(tailscaleIP))
    #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(lanIP))
    #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(localDNS))
    #expect(!MobileShellRouteAuthPolicy.routeAllowsStackAuth(pretendLoopback))
    #expect(!MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("127.0.0.1"))
    #expect(!MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("100.71.210.41"))
    #expect(!MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("work-mac.tailnet.ts.net"))
    #expect(MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("192.168.1.77"))
    #expect(MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("devbox.local"))
}

@Test func pairedMacStorePersistsActiveMacsScopedByStackUser() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("paired-macs.sqlite3"))
    let userARoute = try hostPortRoute(kind: .tailscale, host: "work-a.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)
    let userBRoute = try hostPortRoute(kind: .tailscale, host: "work-b.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)
    let now = Date(timeIntervalSince1970: 1_000)

    try store.upsert(
        macDeviceID: "mac-a",
        displayName: "Work A",
        routes: [userARoute],
        markActive: true,
        stackUserID: "user-a",
        now: now
    )
    try store.upsert(
        macDeviceID: "mac-b",
        displayName: "Work B",
        routes: [userBRoute],
        markActive: true,
        stackUserID: "user-b",
        now: now.addingTimeInterval(10)
    )

    #expect(try store.activeMac(stackUserID: "user-a")?.macDeviceID == "mac-a")
    #expect(try store.activeMac(stackUserID: "user-b")?.macDeviceID == "mac-b")
    #expect(try store.activeMac(stackUserID: "missing") == nil)
    #expect(try store.loadAll(stackUserID: "user-a").map(\.routes).first == [userARoute])
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

@Test func rootAuthGateAllowsAttachTicketAuthenticationWithoutStackAuth() throws {
    #expect(MobileRootAuthGate.isAuthenticated(
        stackAuthenticated: false,
        attachTicketAuthenticated: true
    ))
    #expect(!MobileRootAuthGate.isAuthenticated(
        stackAuthenticated: false,
        attachTicketAuthenticated: false
    ))

    let attachURL = try #require(URL(string: "cmux-ios://attach?v=1&payload=test"))
    let authURL = try #require(URL(string: "stack-auth-mobile-oauth-url://callback?code=test"))
    let otherURL = try #require(URL(string: "cmux-ios://oauth?v=1"))

    #expect(MobileRootAuthGate.isAttachURL(attachURL))
    #expect(!MobileRootAuthGate.isAttachURL(authURL))
    #expect(!MobileRootAuthGate.isAttachURL(otherURL))
}

@Test func rootAuthGateShowsRestoringSessionOnlyBeforeAuthentication() {
    #expect(MobileRootAuthGate.shouldShowRestoringSession(
        stackAuthenticated: false,
        attachTicketAuthenticated: false,
        isRestoringSession: true
    ))
    #expect(!MobileRootAuthGate.shouldShowRestoringSession(
        stackAuthenticated: true,
        attachTicketAuthenticated: false,
        isRestoringSession: true
    ))
    #expect(!MobileRootAuthGate.shouldShowRestoringSession(
        stackAuthenticated: false,
        attachTicketAuthenticated: true,
        isRestoringSession: true
    ))
    #expect(!MobileRootAuthGate.shouldShowRestoringSession(
        stackAuthenticated: false,
        attachTicketAuthenticated: false,
        isRestoringSession: false
    ))
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

@Test func rootAuthGateClearsOnlyStaleTemporaryAttachAuthentication() {
    #expect(MobileRootAuthGate.shouldClearAttachTicketAuthentication(
        pairingResult: .failed,
        connectionState: .disconnected,
        hasActiveUnexpiredTicket: false
    ))
    #expect(MobileRootAuthGate.shouldClearAttachTicketAuthentication(
        pairingResult: .superseded,
        connectionState: .disconnected,
        hasActiveUnexpiredTicket: false
    ))
    #expect(!MobileRootAuthGate.shouldClearAttachTicketAuthentication(
        pairingResult: .superseded,
        connectionState: .connected,
        hasActiveUnexpiredTicket: true
    ))
    #expect(!MobileRootAuthGate.shouldClearAttachTicketAuthentication(
        pairingResult: .connected,
        connectionState: .connected,
        hasActiveUnexpiredTicket: true
    ))
    #expect(MobileRootAuthGate.shouldClearAttachTicketAuthentication(
        pairingResult: .connected,
        connectionState: .connected,
        hasActiveUnexpiredTicket: false
    ))
    #expect(MobileRootAuthGate.shouldReconnectStoredMac(
        stackAuthenticated: true,
        attachTicketAuthenticated: false,
        connectionState: .disconnected
    ))
    #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
        stackAuthenticated: true,
        attachTicketAuthenticated: true,
        connectionState: .disconnected
    ))
    #expect(!MobileRootAuthGate.shouldReconnectStoredMac(
        stackAuthenticated: false,
        attachTicketAuthenticated: true,
        connectionState: .disconnected
    ))
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
    #expect(store.connectionError == "Invalid pairing code.")
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
        try rpcSnapshotResultFrame(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            visibleLines: ["ready"]
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
    #expect(requests.contains { $0.method == "terminal.snapshot" })
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
    #expect(workspaceList.stackAccessToken == nil)
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
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["ready"]
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
    #expect(workspaceLists.allSatisfy { $0.stackAccessToken == nil })
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
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["ready"]
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
    #expect(workspaceLists.allSatisfy { $0.stackAccessToken == nil })
    let workspaceIDs = try await waitForWorkspaceIDs(in: store, matching: [workspaceID, secondWorkspaceID])
    #expect(workspaceIDs == [workspaceID, secondWorkspaceID])
    #expect(store.selectedWorkspace?.terminals.first?.lines.first == "ready")
}

@MainActor
@Test func scopedAttachTicketFallsBackToStackAuthForOutOfScopeTerminalTraffic() async throws {
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
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["scoped ready"]
        ),
        try rpcSnapshotResultFrame(
            workspaceID: secondWorkspaceID,
            terminalID: secondTerminalID,
            visibleLines: ["second ready"]
        ),
        try rpcResultFrame(result: ["accepted": true]),
        try rpcSnapshotResultFrame(
            workspaceID: secondWorkspaceID,
            terminalID: secondTerminalID,
            visibleLines: ["second typed"]
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "test-stack-token"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    _ = try await waitForWorkspaceIDs(in: store, matching: [workspaceID, secondWorkspaceID])

    await store.openWorkspace(MobileWorkspacePreview.ID(rawValue: secondWorkspaceID))
    await store.submitTerminalRawInput("x")
    let terminal = try await waitForSelectedTerminal(in: store) {
        $0.snapshot.renderedVisibleLines.first == "second typed"
    }
    #expect(terminal.id.rawValue == secondTerminalID)

    let requests = try await responses.sentRequests()
    let secondWorkspaceSnapshots = requests.filter {
        $0.method == "terminal.snapshot" &&
            $0.workspaceID == secondWorkspaceID &&
            $0.terminalID == secondTerminalID
    }
    let secondWorkspaceInput = try #require(requests.first {
        $0.method == "terminal.input" &&
            $0.workspaceID == secondWorkspaceID &&
            $0.terminalID == secondTerminalID
    })

    #expect(!secondWorkspaceSnapshots.isEmpty)
    #expect(secondWorkspaceSnapshots.allSatisfy { $0.attachToken == nil })
    #expect(secondWorkspaceSnapshots.allSatisfy { $0.stackAccessToken == "test-stack-token" })
    #expect(secondWorkspaceInput.attachToken == nil)
    #expect(secondWorkspaceInput.stackAccessToken == "test-stack-token")
}

@MainActor
@Test func macScopedAttachTicketKeepsAttachTokenForWorkspaceSwitches() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let secondWorkspaceID = UUID().uuidString
    let secondTerminalID = UUID().uuidString
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let ticket = try CmxAttachTicket(
        workspaceID: "",
        terminalID: nil,
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
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["ready"]
        ),
        try rpcSnapshotResultFrame(
            workspaceID: secondWorkspaceID,
            terminalID: secondTerminalID,
            visibleLines: ["second ready"]
        ),
        try rpcResultFrame(result: ["accepted": true]),
        try rpcSnapshotResultFrame(
            workspaceID: secondWorkspaceID,
            terminalID: secondTerminalID,
            visibleLines: ["second typed"]
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: "test-stack-token"
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    _ = try await waitForWorkspaceIDs(in: store, matching: [workspaceID, secondWorkspaceID])

    await store.openWorkspace(MobileWorkspacePreview.ID(rawValue: secondWorkspaceID))
    await store.submitTerminalRawInput("x")
    let terminal = try await waitForSelectedTerminal(in: store) {
        $0.snapshot.renderedVisibleLines.first == "second typed"
    }
    #expect(terminal.id.rawValue == secondTerminalID)

    let requests = try await responses.sentRequests()
    let secondWorkspaceSnapshots = requests.filter {
        $0.method == "terminal.snapshot" &&
            $0.workspaceID == secondWorkspaceID &&
            $0.terminalID == secondTerminalID
    }
    let secondWorkspaceInput = try #require(requests.first {
        $0.method == "terminal.input" &&
            $0.workspaceID == secondWorkspaceID &&
            $0.terminalID == secondTerminalID
    })

    #expect(!secondWorkspaceSnapshots.isEmpty)
    #expect(secondWorkspaceSnapshots.allSatisfy { $0.attachToken == "ticket-secret" })
    #expect(secondWorkspaceSnapshots.allSatisfy { $0.stackAccessToken == nil })
    #expect(secondWorkspaceInput.attachToken == "ticket-secret")
    #expect(secondWorkspaceInput.stackAccessToken == nil)
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
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["scoped fallback"]
        ),
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
    #expect(store.selectedWorkspace?.terminals.first?.lines.first == "scoped fallback")
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
    #expect(workspaceList.stackAccessToken == nil)
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
    #expect(try pairedMacStore.activeMac() == nil)
    #expect(try pairedMacStore.loadAll().isEmpty)
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
    #expect(store.selectedWorkspace?.id.rawValue == "stale-workspace")
    #expect(store.selectedTerminalID?.rawValue == "stale-terminal")
    #expect(store.selectedWorkspace?.terminals.first?.lines.first == "Terminal surface is still starting.")
}

@MainActor
@Test func staleNotReadySnapshotDoesNotSelectFallbackAfterUserSelectionChanges() async throws {
    let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    let router = StaleSnapshotSelectionRouter(route: route)
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router)
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    let connectTask = Task { @MainActor in
        await store.connectManualHost(name: "", host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
    }

    await router.waitForStaleSnapshotRequest()
    await store.openWorkspace(.init(rawValue: "chosen-workspace"))
    await router.releaseStaleSnapshotError()
    await connectTask.value

    for _ in 0..<100 {
        if store.selectedWorkspace?.id.rawValue == "chosen-workspace",
           store.selectedTerminalID?.rawValue == "chosen-terminal",
           store.selectedWorkspace?.terminals.first?.lines.first == "chosen stays selected" {
            break
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    let requests = await router.sentRequests()
    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.id.rawValue == "chosen-workspace")
    #expect(store.selectedTerminalID?.rawValue == "chosen-terminal")
    #expect(store.selectedWorkspace?.terminals.first?.lines.first == "chosen stays selected")
    #expect(!requests.contains { $0.workspaceID == "fallback-workspace" })
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

    for _ in 0..<200 where store.selectedWorkspace?.id.rawValue != "workspace-3" ||
        store.selectedWorkspace?.terminals.first?.lines.contains("workspace: Workspace 3") != true {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(store.selectedWorkspace?.id.rawValue == "workspace-3")
    #expect(store.selectedTerminalID?.rawValue == "workspace-3-terminal-1")
    #expect(store.workspaces.map(\.id.rawValue) == ["workspace-main", "workspace-3"])
    #expect(store.selectedWorkspace?.terminals.first?.lines.contains("workspace: Workspace 3") == true)
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

    for _ in 0..<200 where store.selectedWorkspace?.id.rawValue != "workspace-3" ||
        store.selectedWorkspace?.terminals.first?.lines.contains("workspace: Workspace 3") != true {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    let requests = await router.sentRequests()
    let createRequest = try #require(requests.first { $0.method == "workspace.create" })
    #expect(createRequest.attachToken == "ticket-secret")
    #expect(createRequest.stackAccessToken == nil)
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

    for _ in 0..<200 where store.selectedTerminalID?.rawValue != "workspace-main-terminal-2" ||
        store.selectedWorkspace?.terminals.first(where: { $0.id.rawValue == "workspace-main-terminal-2" })?.lines
            .contains("terminal: Terminal 2") != true {
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

    for _ in 0..<200 where store.selectedTerminalID?.rawValue != "terminal-notes" ||
        store.selectedWorkspace?.terminals.first?.lines.first != "docs after create race" {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    let requests = await router.sentRequests()
    #expect(store.connectionError == nil)
    #expect(store.selectedWorkspace?.id.rawValue == "workspace-docs")
    #expect(store.selectedTerminalID?.rawValue == "terminal-notes")
    #expect(store.selectedWorkspace?.terminals.first?.lines.first == "docs after create race")
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

@Test func compactNavigationDoesNotAutoPushWhenAttachSelectsWorkspace() {
    let path = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
        currentPath: [MobileWorkspacePreview.ID](),
        selectedWorkspaceID: .init(rawValue: "workspace-a")
    )

    #expect(path.isEmpty)
}

@Test func compactNavigationPushesNewlyCreatedWorkspaceFromList() {
    let path = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
        currentPath: [MobileWorkspacePreview.ID](),
        selectedWorkspaceID: .init(rawValue: "workspace-created"),
        existingWorkspaceIDs: [
            .init(rawValue: "workspace-a"),
            .init(rawValue: "workspace-b"),
        ]
    )

    #expect(path == [MobileWorkspacePreview.ID(rawValue: "workspace-created")])
}

@Test func compactNavigationDoesNotTreatExistingSelectionAsCreatedWorkspace() {
    let path = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
        currentPath: [MobileWorkspacePreview.ID](),
        selectedWorkspaceID: .init(rawValue: "workspace-a"),
        existingWorkspaceIDs: [
            .init(rawValue: "workspace-a"),
            .init(rawValue: "workspace-b"),
        ]
    )

    #expect(path == nil)
}

@Test func compactNavigationIgnoresCreatedWorkspaceSelectionWhenNoCreateIsPending() {
    let path = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
        currentPath: [MobileWorkspacePreview.ID](),
        selectedWorkspaceID: .init(rawValue: "workspace-created"),
        existingWorkspaceIDs: nil
    )

    #expect(path == nil)
}

@Test func compactNavigationTracksSelectionAfterUserOpenedWorkspace() {
    let path = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
        currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
        selectedWorkspaceID: MobileWorkspacePreview.ID(rawValue: "workspace-b")
    )

    #expect(path == [MobileWorkspacePreview.ID(rawValue: "workspace-b")])
}

@Test func compactNavigationClearsWhenSelectedWorkspaceDisappears() {
    let path = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
        currentPath: [MobileWorkspacePreview.ID(rawValue: "workspace-a")],
        selectedWorkspaceID: nil
    )

    #expect(path.isEmpty)
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
    let workspaceA = MobileWorkspacePreview.ID(rawValue: "workspace-a")
    let terminalA = MobileTerminalPreview.ID(rawValue: "terminal-a")
    let terminalB = MobileTerminalPreview.ID(rawValue: "terminal-b")

    let startsDrain = buffer.enqueue("p", workspaceID: workspaceA, terminalID: terminalA)
    let appendsWhileDraining = buffer.enqueue("rint", workspaceID: workspaceA, terminalID: terminalA)
    let appendsFinalCharacter = buffer.enqueue("f", workspaceID: workspaceA, terminalID: terminalA)
    #expect(startsDrain == .startDraining)
    #expect(appendsWhileDraining == .queued)
    #expect(appendsFinalCharacter == .queued)
    let firstBatch = buffer.nextBatch()
    #expect(firstBatch?.workspaceID == workspaceA)
    #expect(firstBatch?.terminalID == terminalA)
    #expect(firstBatch?.text == "printf")

    let appendsSecondBatch = buffer.enqueue(" 'one'", workspaceID: workspaceA, terminalID: terminalA)
    #expect(appendsSecondBatch == .queued)
    #expect(buffer.nextBatch()?.text == " 'one'")
    #expect(buffer.nextBatch() == nil)

    let restartsDrain = buffer.enqueue("\r", workspaceID: workspaceA, terminalID: terminalB)
    #expect(restartsDrain == .startDraining)
    let terminalBBatch = buffer.nextBatch()
    #expect(terminalBBatch?.terminalID == terminalB)
    #expect(terminalBBatch?.text == "\r")
}

@Test func rawTerminalInputSendBufferRejectsOverflowUntilPendingInputDrains() {
    var buffer = MobileTerminalInputSendBuffer()
    let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-a")
    let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-a")
    let fullBufferText = String(repeating: "a", count: MobileTerminalInputSendBuffer.maximumPendingByteCount)

    #expect(buffer.enqueue(fullBufferText, workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
    #expect(buffer.pendingByteCount == MobileTerminalInputSendBuffer.maximumPendingByteCount)
    #expect(buffer.enqueue("b", workspaceID: workspaceID, terminalID: terminalID) == .rejected)
    #expect(buffer.pendingByteCount == MobileTerminalInputSendBuffer.maximumPendingByteCount)

    let batch = buffer.nextBatch()
    #expect(batch?.text == fullBufferText)
    #expect(buffer.pendingByteCount == 0)
    #expect(buffer.enqueue("b", workspaceID: workspaceID, terminalID: terminalID) == .queued)
    #expect(buffer.nextBatch()?.text == "b")
    #expect(buffer.nextBatch() == nil)
    #expect(buffer.enqueue("c", workspaceID: workspaceID, terminalID: terminalID) == .startDraining)
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

    state.tap(.shift, now: start.addingTimeInterval(0.5))
    #expect(state.activeModifier == .shift)
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

#if canImport(UIKit)
@Test func terminalHardwareDeleteUsesTextInputBackspacePath() {
    #expect(MobileTerminalHardwareKeyResolver.input(UIKeyCommand.inputDelete, modifierFlags: []) == nil)
    #expect(MobileTerminalHardwareKeyResolver.input(UIKeyCommand.inputDelete, modifierFlags: .alternate) == "\u{1B}\u{7F}")
}
#endif

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
@Test func serverPushSubscriptionKeepsTerminalPollingFallbackAndSingleListener() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let router = ServerPushPollingFallbackRouter(
        workspaceID: workspaceID,
        terminalID: terminalID
    )
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        stackAccessToken: nil,
        supportsServerPushEvents: true
    )
    weak var weakStore: CMUXMobileShellStore?
    do {
        let store = CMUXMobileShellStore.preview(runtime: runtime)
        weakStore = store

        store.signIn()
        await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
        _ = try await waitForRequestCount("mobile.events.subscribe", count: 1, router: router)
        store.resumeForegroundRefresh()

        _ = try await waitForRequestCount("terminal.snapshot", count: 2, router: router)
        try await Task.sleep(nanoseconds: 50_000_000)

        let requests = await router.sentRequests()
        let subscribeRequests = requests.filter { $0.method == "mobile.events.subscribe" }
        #expect(subscribeRequests.count == 1)
        #expect(subscribeRequests.allSatisfy { $0.attachToken == "ticket-secret" })
        #expect(subscribeRequests.allSatisfy { $0.stackAccessToken == nil })
        #expect(requests.filter { $0.method == "terminal.snapshot" }.count >= 2)
    }
    #expect(weakStore == nil)
}

@MainActor
@Test func selectingTerminalWhileSnapshotRefreshIsInFlightFetchesSelectedTerminalSnapshot() async throws {
    let workspaceID = "workspace-main"
    let buildTerminalID = "terminal-build"
    let tuiTerminalID = "terminal-tui"
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: nil,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let router = TerminalSelectionRefreshRouter(
        workspaceID: workspaceID,
        buildTerminalID: buildTerminalID,
        tuiTerminalID: tuiTerminalID
    )
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        stackAccessToken: nil
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)
    let pairingURL = try attachURL(for: ticket).absoluteString

    store.signIn()
    let connectTask = Task {
        await store.connectPairingURL(pairingURL)
    }
    let initialSnapshots = try await waitForRequestCount("terminal.snapshot", count: 1, router: router)
    #expect(initialSnapshots.first?.terminalID == buildTerminalID)

    store.selectTerminal(MobileTerminalPreview.ID(rawValue: tuiTerminalID))
    await router.releaseBuildSnapshot()
    #expect(await connectTask.value)
    let snapshotsAfterSelection = try await waitForRequestCount("terminal.snapshot", count: 2, router: router)
    #expect(snapshotsAfterSelection.contains {
        $0.workspaceID == workspaceID && $0.terminalID == tuiTerminalID
    })

    let selectedTerminal = try await waitForSelectedTerminal(in: store) {
        $0.id.rawValue == tuiTerminalID && $0.snapshot.renderedVisibleLines.first == "LAZYGIT"
    }
    #expect(selectedTerminal.id.rawValue == tuiTerminalID)
}

@MainActor
@Test func rawTerminalInputDoesNotReplaceStyledSnapshotWithImmediatePlainTextDowngrade() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let initialStyledSnapshot = try ansiSnapshot(
        terminalID: terminalID,
        text: "\u{001B}[38;2;204;102;102mred prompt\u{001B}[0m"
    )
    let refreshedStyledSnapshot = try ansiSnapshot(
        terminalID: terminalID,
        text: "\u{001B}[38;2;204;102;102mred prompt x\u{001B}[0m"
    )
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: workspaceID,
            title: "Live Workspace",
            terminalID: terminalID
        ),
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["red prompt"],
            fidelity: "ansi_vt",
            snapshotOverride: initialStyledSnapshot
        ),
        try rpcResultFrame(result: ["accepted": true]),
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["plain prompt x"],
            fidelity: "plain_text"
        ),
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["red prompt x"],
            fidelity: "ansi_vt",
            snapshotOverride: refreshedStyledSnapshot
        ),
    ])
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: nil
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    await store.submitTerminalRawInput("x")

    let terminal = try await waitForSelectedTerminal(in: store) {
        $0.snapshot.renderedVisibleLines.first == "red prompt x"
    }
    #expect(terminal.snapshot.renderedVisibleLines.first == "red prompt x")
    #expect(terminal.snapshot.visibleRows[0].cells[0].style.foreground == MobileTerminalGhosttyColor(red: 204, green: 102, blue: 102))

    let requests = try await responses.sentRequests()
    #expect(requests.filter { $0.method == "terminal.snapshot" }.count >= 2)
    #expect(requests.contains { $0.method == "terminal.input" && $0.text == "x" })
}

@MainActor
@Test func rawTerminalInputKeepsMatchingStylesWhenOnlyPlainTextSnapshotsReturn() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let plainTextRefreshes = try (0..<4).map { _ in
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["red prompt x"],
            fidelity: "plain_text",
            snapshotOverride: try MobileTerminalGhosttySnapshot.fixture(
                terminalID: terminalID,
                columns: 32,
                rows: 2,
                visibleLines: ["red prompt x"]
            )
        )
    }
    let responses = ScriptedTransportResponses([
        try rpcWorkspaceListFrame(
            workspaceID: workspaceID,
            title: "Live Workspace",
            terminalID: terminalID
        ),
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["red prompt"],
            fidelity: "ansi_vt",
            snapshotOverride: styledPromptSnapshot(terminalID: terminalID, suffix: "")
        ),
        try rpcResultFrame(result: ["accepted": true]),
    ] + plainTextRefreshes)
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: nil
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    await store.submitTerminalRawInput("x")

    let terminal = try await waitForSelectedTerminal(in: store) {
        $0.snapshot.renderedVisibleLines.first == "red prompt x"
    }
    #expect(terminal.snapshot.visibleRows[0].cells[0].style.foreground == MobileTerminalGhosttyColor(red: 204, green: 102, blue: 102))
    #expect(terminal.snapshot.visibleRows[0].cells[9].style.foreground == MobileTerminalGhosttyColor(red: 204, green: 102, blue: 102))
    #expect(terminal.snapshot.visibleRows[0].cells[10].style == MobileTerminalGhosttyCellStyle())

    let requests = try await responses.sentRequests()
    #expect(requests.contains { $0.method == "terminal.input" && $0.text == "x" })
}

@MainActor
@Test func rawTerminalInputPreservesStyledGridAndCursorForEveryKeystroke() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )

    var frames: [Data] = [
        try rpcWorkspaceListFrame(
            workspaceID: workspaceID,
            title: "Live Workspace",
            terminalID: terminalID
        ),
        try rpcSnapshotResultFrame(
            workspaceID: workspaceID,
            terminalID: terminalID,
            visibleLines: ["red prompt"],
            fidelity: "ansi_vt",
            snapshotOverride: styledPromptSnapshot(terminalID: terminalID, suffix: "")
        ),
    ]
    var expectedSuffix = ""
    for character in ["a", "b", "c"] {
        expectedSuffix += character
        frames.append(try rpcResultFrame(result: ["accepted": true]))
        frames.append(
            try rpcSnapshotResultFrame(
                workspaceID: workspaceID,
                terminalID: terminalID,
                visibleLines: ["plain prompt \(expectedSuffix)"],
                fidelity: "plain_text"
            )
        )
        frames.append(
            try rpcSnapshotResultFrame(
                workspaceID: workspaceID,
                terminalID: terminalID,
                visibleLines: ["red prompt \(expectedSuffix)"],
                fidelity: "ansi_vt",
                snapshotOverride: styledPromptSnapshot(terminalID: terminalID, suffix: expectedSuffix)
            )
        )
    }

    let responses = ScriptedTransportResponses(frames)
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: responses),
        stackAccessToken: nil
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    try assertStyledPrompt(try #require(store.selectedWorkspace?.terminals.first), suffix: "")

    expectedSuffix = ""
    for character in ["a", "b", "c"] {
        expectedSuffix += character
        await store.submitTerminalRawInput(character)
        let terminal = try await waitForSelectedTerminal(in: store) {
            $0.snapshot.renderedVisibleLines.first == "red prompt \(expectedSuffix)"
        }
        try assertStyledPrompt(terminal, suffix: expectedSuffix)
        #expect(!terminal.snapshot.renderedVisibleLines.contains { $0.contains("plain prompt") })
    }

    let requests = try await responses.sentRequests()
    #expect(requests.filter { $0.method == "terminal.input" }.map(\.text) == ["a", "b", "c"])
    #expect(requests.filter { $0.method == "terminal.snapshot" }.count == 7)
}

@MainActor
@Test func queuedRawTerminalInputDoesNotRenderPlainTextFallbackBeforeStyledRefresh() async throws {
    let workspaceID = UUID().uuidString
    let terminalID = UUID().uuidString
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: workspaceID,
        terminalID: terminalID,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(60),
        authToken: "ticket-secret"
    )
    let router = PlainFallbackDuringInputRouter(
        workspaceID: workspaceID,
        terminalID: terminalID
    )
    let runtime = testRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: RequestAwareTransportFactory(router: router),
        stackAccessToken: nil
    )
    let store = CMUXMobileShellStore.preview(runtime: runtime)

    store.signIn()
    await store.connectPairingURL(try attachURL(for: ticket).absoluteString)
    try assertStyledPrompt(try #require(store.selectedWorkspace?.terminals.first), suffix: "")

    store.sendTerminalRawInput("a")
    await router.waitForStyledRefreshRequest()

    let intermediate = try #require(store.selectedWorkspace?.terminals.first)
    try assertStyledPrompt(intermediate, suffix: "")
    #expect(!intermediate.snapshot.renderedVisibleLines.contains { $0.contains("plain prompt") })

    await router.releaseStyledRefresh()
    let final = try await waitForSelectedTerminal(in: store) {
        $0.snapshot.renderedVisibleLines.first == "red prompt a"
    }
    try assertStyledPrompt(final, suffix: "a")

    let requests = await router.sentRequests()
    #expect(requests.filter { $0.method == "terminal.input" }.map(\.text) == ["a"])
    #expect(requests.filter { $0.method == "terminal.snapshot" }.count == 3)
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

@Test func terminalSnapshotRequestPolicyRequestsVisibleViewportOnly() {
    let phoneRows = MobileTerminalSnapshotRequestPolicy.maxScrollbackRows(
        viewportSize: MobileTerminalViewportSize(columns: 54, rows: 42)
    )
    let wideRows = MobileTerminalSnapshotRequestPolicy.maxScrollbackRows(
        viewportSize: MobileTerminalViewportSize(columns: 300, rows: 120)
    )

    #expect(phoneRows == 0)
    #expect(wideRows == 0)
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

    #expect(store.connectionError == "Could not connect to your computer.")
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
        ) == 0
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

@Test func terminalCellLayoutPolicyKeepsWideGlyphsAtTwoColumns() {
    let row = MobileTerminalGhosttyRow(cells: [
        MobileTerminalGhosttyCell(text: "a"),
        MobileTerminalGhosttyCell(text: "界", width: .wide),
        MobileTerminalGhosttyCell(width: .spacerTail),
        MobileTerminalGhosttyCell(text: "b"),
    ])

    let cells = TerminalRowCellProjection.cells(
        from: row,
        preservingCursorColumn: nil,
        minimumColumnCount: 4
    )
    let renderedColumns = cells.reduce(0) { partial, cell in
        partial + TerminalCellLayoutPolicy.columnSpan(for: cell.width)
    }

    #expect(cells.map(\.width) == [.narrow, .wide, .spacerTail, .narrow])
    #expect(renderedColumns == 4)
    #expect(TerminalCellLayoutPolicy.columnSpan(for: .wide) == 2)
    #expect(TerminalCellLayoutPolicy.columnSpan(for: .spacerTail) == 0)
}

private struct MissingTestStackAccessToken: Error {}

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

private struct QueuedCancellationProbeTransportFactory: CmxByteTransportFactory {
    let transport: QueuedCancellationProbeTransport

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
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

private actor StaleSnapshotSelectionRouter: RequestAwareTransportRouter {
    private let route: CmxAttachRoute
    private var staleSnapshotRequested = false
    private var staleSnapshotReleased = false
    private var staleSnapshotReleaseContinuation: CheckedContinuation<Void, Never>?
    private var staleSnapshotRequestWaiters: [CheckedContinuation<Void, Never>] = []
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

    func waitForStaleSnapshotRequest() async {
        guard !staleSnapshotRequested else { return }
        await withCheckedContinuation { continuation in
            staleSnapshotRequestWaiters.append(continuation)
        }
    }

    func releaseStaleSnapshotError() {
        staleSnapshotReleased = true
        staleSnapshotReleaseContinuation?.resume()
        staleSnapshotReleaseContinuation = nil
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "mobile.attach_ticket.create":
            return try rpcAttachTicketFrame(route: route, workspaceID: "stale-workspace")
        case "workspace.list":
            return try workspaceListFrame()
        case "terminal.snapshot":
            if request.workspaceID == "stale-workspace", request.terminalID == "stale-terminal" {
                markStaleSnapshotRequested()
                await waitForStaleSnapshotRelease()
                return try rpcErrorFrame(message: "Terminal surface is not ready")
            }
            if request.workspaceID == "fallback-workspace", request.terminalID == "fallback-terminal" {
                return try rpcSnapshotResultFrame(
                    workspaceID: "fallback-workspace",
                    terminalID: "fallback-terminal",
                    visibleLines: ["fallback should not steal selection"]
                )
            }
            if request.workspaceID == "chosen-workspace", request.terminalID == "chosen-terminal" {
                return try rpcSnapshotResultFrame(
                    workspaceID: "chosen-workspace",
                    terminalID: "chosen-terminal",
                    visibleLines: ["chosen stays selected"]
                )
            }
            return try rpcErrorFrame(message: "Unexpected terminal snapshot request")
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }

    private func markStaleSnapshotRequested() {
        staleSnapshotRequested = true
        let waiters = staleSnapshotRequestWaiters
        staleSnapshotRequestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForStaleSnapshotRelease() async {
        guard !staleSnapshotReleased else { return }
        await withCheckedContinuation { continuation in
            staleSnapshotReleaseContinuation = continuation
        }
    }

    private func workspaceListFrame() throws -> Data {
        try rpcResultFrame(
            result: [
                "workspaces": [
                    workspaceObject(
                        id: "stale-workspace",
                        title: "Stale Workspace",
                        terminalID: "stale-terminal",
                        terminalTitle: "Stale Terminal",
                        isReady: false,
                        isSelected: true
                    ),
                    workspaceObject(
                        id: "fallback-workspace",
                        title: "Fallback Workspace",
                        terminalID: "fallback-terminal",
                        terminalTitle: "Fallback Terminal",
                        isReady: true,
                        isSelected: false
                    ),
                    workspaceObject(
                        id: "chosen-workspace",
                        title: "Chosen Workspace",
                        terminalID: "chosen-terminal",
                        terminalTitle: "Chosen Terminal",
                        isReady: true,
                        isSelected: false
                    ),
                ],
            ]
        )
    }

    private func workspaceObject(
        id: String,
        title: String,
        terminalID: String,
        terminalTitle: String,
        isReady: Bool,
        isSelected: Bool
    ) -> [String: Any] {
        [
            "id": id,
            "title": title,
            "current_directory": "/Users/test/\(id)",
            "is_selected": isSelected,
            "terminals": [
                [
                    "id": terminalID,
                    "title": terminalTitle,
                    "current_directory": "/Users/test/\(id)",
                    "is_ready": isReady,
                    "is_focused": true,
                ],
            ],
        ]
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
        case "terminal.snapshot":
            let workspaceID = request.workspaceID ?? "second-workspace"
            let terminalID = request.terminalID ?? "\(workspaceID)-terminal"
            return try rpcSnapshotResultFrame(
                workspaceID: workspaceID,
                terminalID: terminalID,
                visibleLines: ["attached to \(workspaceID)"]
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
        case "terminal.snapshot":
            if request.workspaceID == "workspace-main", request.terminalID == "workspace-main-terminal-2" {
                return try rpcSnapshotResultFrame(
                    workspaceID: "workspace-main",
                    terminalID: "workspace-main-terminal-2",
                    visibleLines: [
                        "$ cmux ios",
                        "workspace: cmux",
                        "terminal: Terminal 2",
                    ]
                )
            }
            return try rpcSnapshotResultFrame(
                workspaceID: "workspace-main",
                terminalID: "terminal-build",
                visibleLines: ["initial"]
            )
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
        case "terminal.snapshot":
            if request.workspaceID == "workspace-docs", request.terminalID == "terminal-notes" {
                return try rpcSnapshotResultFrame(
                    workspaceID: "workspace-docs",
                    terminalID: "terminal-notes",
                    visibleLines: ["docs after create race"]
                )
            }
            if request.workspaceID == "workspace-main", request.terminalID == "terminal-build" {
                return try rpcSnapshotResultFrame(
                    workspaceID: "workspace-main",
                    terminalID: "terminal-build",
                    visibleLines: ["initial main"]
                )
            }
            return try rpcErrorFrame(message: "Unexpected terminal snapshot request")
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

private actor PlainFallbackDuringInputRouter: RequestAwareTransportRouter {
    private let workspaceID: String
    private let terminalID: String
    private var snapshotRequestCount = 0
    private var styledRefreshRequested = false
    private var styledRefreshReleased = false
    private var styledRefreshRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var styledRefreshReleaseContinuation: CheckedContinuation<Void, Never>?
    private var requests: [RecordedRPCRequest] = []

    init(workspaceID: String, terminalID: String) {
        self.workspaceID = workspaceID
        self.terminalID = terminalID
    }

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func waitForStyledRefreshRequest() async {
        guard !styledRefreshRequested else { return }
        await withCheckedContinuation { continuation in
            styledRefreshRequestWaiters.append(continuation)
        }
    }

    func releaseStyledRefresh() {
        styledRefreshReleased = true
        styledRefreshReleaseContinuation?.resume()
        styledRefreshReleaseContinuation = nil
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try rpcWorkspaceListFrame(
                workspaceID: workspaceID,
                title: "Live Workspace",
                terminalID: terminalID
            )
        case "terminal.input":
            return try rpcResultFrame(result: ["accepted": true])
        case "terminal.snapshot":
            snapshotRequestCount += 1
            if snapshotRequestCount == 1 {
                return try rpcSnapshotResultFrame(
                    workspaceID: workspaceID,
                    terminalID: terminalID,
                    visibleLines: ["red prompt"],
                    fidelity: "ansi_vt",
                    snapshotOverride: styledPromptSnapshot(terminalID: terminalID, suffix: "")
                )
            }
            if snapshotRequestCount == 2 {
                return try rpcSnapshotResultFrame(
                    workspaceID: workspaceID,
                    terminalID: terminalID,
                    visibleLines: ["plain prompt a"],
                    fidelity: "plain_text"
                )
            }
            markStyledRefreshRequested()
            await waitForStyledRefreshRelease()
            return try rpcSnapshotResultFrame(
                workspaceID: workspaceID,
                terminalID: terminalID,
                visibleLines: ["red prompt a"],
                fidelity: "ansi_vt",
                snapshotOverride: styledPromptSnapshot(terminalID: terminalID, suffix: "a")
            )
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }

    private func markStyledRefreshRequested() {
        styledRefreshRequested = true
        let waiters = styledRefreshRequestWaiters
        styledRefreshRequestWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForStyledRefreshRelease() async {
        guard !styledRefreshReleased else { return }
        await withCheckedContinuation { continuation in
            styledRefreshReleaseContinuation = continuation
        }
    }
}

private actor ServerPushPollingFallbackRouter: RequestAwareTransportRouter {
    private let workspaceID: String
    private let terminalID: String
    private var snapshotRequestCount = 0
    private var requests: [RecordedRPCRequest] = []

    init(workspaceID: String, terminalID: String) {
        self.workspaceID = workspaceID
        self.terminalID = terminalID
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
                workspaceID: workspaceID,
                title: "Live Workspace",
                terminalID: terminalID
            )
        case "mobile.events.subscribe":
            return try rpcResultFrame(result: [
                "stream_id": "test-stream",
                "topics": ["terminal.updated", "workspace.updated"],
            ])
        case "terminal.snapshot":
            snapshotRequestCount += 1
            return try rpcSnapshotResultFrame(
                workspaceID: workspaceID,
                terminalID: terminalID,
                visibleLines: ["snapshot \(snapshotRequestCount)"]
            )
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }
}

private actor TerminalSelectionRefreshRouter: RequestAwareTransportRouter {
    private let workspaceID: String
    private let buildTerminalID: String
    private let tuiTerminalID: String
    private var buildSnapshotReleased = false
    private var buildSnapshotReleaseContinuation: CheckedContinuation<Void, Never>?
    private var requests: [RecordedRPCRequest] = []

    init(workspaceID: String, buildTerminalID: String, tuiTerminalID: String) {
        self.workspaceID = workspaceID
        self.buildTerminalID = buildTerminalID
        self.tuiTerminalID = tuiTerminalID
    }

    func record(_ request: RecordedRPCRequest) {
        requests.append(request)
    }

    func sentRequests() -> [RecordedRPCRequest] {
        requests
    }

    func releaseBuildSnapshot() {
        buildSnapshotReleased = true
        buildSnapshotReleaseContinuation?.resume()
        buildSnapshotReleaseContinuation = nil
    }

    func response(for request: RecordedRPCRequest) async throws -> Data? {
        switch request.method {
        case "workspace.list":
            return try workspaceListFrame()
        case "terminal.snapshot":
            if request.workspaceID == workspaceID, request.terminalID == buildTerminalID {
                await waitForBuildSnapshotRelease()
                return try rpcSnapshotResultFrame(
                    workspaceID: workspaceID,
                    terminalID: buildTerminalID,
                    visibleLines: ["BUILD"]
                )
            }
            if request.workspaceID == workspaceID, request.terminalID == tuiTerminalID {
                return try rpcSnapshotResultFrame(
                    workspaceID: workspaceID,
                    terminalID: tuiTerminalID,
                    visibleLines: ["LAZYGIT"]
                )
            }
            return try rpcErrorFrame(message: "Unexpected terminal snapshot request")
        default:
            return try rpcErrorFrame(message: "Unexpected method \(request.method ?? "nil")")
        }
    }

    private func waitForBuildSnapshotRelease() async {
        guard !buildSnapshotReleased else { return }
        await withCheckedContinuation { continuation in
            buildSnapshotReleaseContinuation = continuation
        }
    }

    private func workspaceListFrame() throws -> Data {
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
                                "id": buildTerminalID,
                                "title": "Build",
                                "current_directory": "/Users/test/project",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                            [
                                "id": tuiTerminalID,
                                "title": "TUI",
                                "current_directory": "/Users/test/project",
                                "is_ready": true,
                                "is_focused": false,
                            ],
                        ],
                    ],
                ],
            ]
        )
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
        case "terminal.snapshot":
            if request.workspaceID == "workspace-3",
               request.terminalID == "workspace-3-terminal-1" {
                return try rpcSnapshotResultFrame(
                    workspaceID: "workspace-3",
                    terminalID: "workspace-3-terminal-1",
                    visibleLines: [
                        "$ cmux ios",
                        "workspace: Workspace 3",
                        "terminal: Terminal 1",
                    ]
                )
            }
            return try rpcSnapshotResultFrame(
                workspaceID: "workspace-main",
                terminalID: "terminal-build",
                visibleLines: ["initial"]
            )
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
    var hasAuth: Bool
    var attachToken: String?
    var stackAccessToken: String?
}

private actor AsyncFlag {
    private var value = false

    func set() {
        value = true
    }

    func isSet() -> Bool {
        value
    }
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

private actor QueuedCancellationProbeTransport: CmxByteTransport {
    private var sentPayloads: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var firstSendRelease: CheckedContinuation<Void, Never>?
    private var shouldBlockFirstSend = true
    private var isClosed = false

    func connect() async throws {}

    func receive() async throws -> Data? {
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
        sentPayloads.append(contentsOf: payloads)
        if shouldBlockFirstSend {
            shouldBlockFirstSend = false
            await withCheckedContinuation { continuation in
                firstSendRelease = continuation
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
        releaseFirstSend()
    }

    func releaseFirstSend() {
        firstSendRelease?.resume()
        firstSendRelease = nil
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map(recordedRPCRequest(from:))
    }

    func waitForSentRequestCount(_ count: Int) async throws -> [RecordedRPCRequest] {
        var requests: [RecordedRPCRequest] = []
        for _ in 0..<200 {
            requests = try sentRequests()
            if requests.count >= count {
                return requests
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return requests
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

private func rpcSnapshotResultFrame(
    workspaceID: String,
    terminalID: String,
    visibleLines: [String],
    viewportFit: [String: Any]? = nil,
    fidelity: String? = nil,
    snapshotOverride: MobileTerminalGhosttySnapshot? = nil
) throws -> Data {
    let snapshot: MobileTerminalGhosttySnapshot
    if let snapshotOverride {
        snapshot = snapshotOverride
    } else {
        snapshot = try MobileTerminalGhosttySnapshot.fixture(
            terminalID: terminalID,
            visibleLines: visibleLines
        )
    }
    let snapshotObject = try JSONSerialization.jsonObject(with: snapshot.encodedValidatedJSON())
    var result: [String: Any] = [
        "workspace_id": workspaceID,
        "surface_id": terminalID,
        "snapshot": snapshotObject,
    ]
    if let viewportFit {
        result["viewport_fit"] = viewportFit
    }
    if let fidelity {
        result["fidelity"] = fidelity
    }
    return try rpcResultFrame(result: result)
}

private func ansiSnapshot(
    terminalID: String,
    text: String,
    columns: Int = 24,
    rows: Int = 2
) throws -> MobileTerminalGhosttySnapshot {
    try MobileTerminalGhosttySnapshot.fromGhosttyText(
        terminalID: terminalID,
        columns: columns,
        rows: rows,
        scrollbackText: nil,
        viewportText: text
    )
}

private func styledPromptSnapshot(terminalID: String, suffix: String) throws -> MobileTerminalGhosttySnapshot {
    let prompt = suffix.isEmpty ? "red prompt" : "red prompt \(suffix)"
    return try ansiSnapshot(
        terminalID: terminalID,
        text: "\u{001B}[38;2;204;102;102m\(prompt)\u{001B}[0m",
        columns: 32,
        rows: 2
    )
}

@MainActor
private func waitForSelectedTerminal(
    in store: CMUXMobileShellStore,
    maxAttempts: Int = 300,
    matching predicate: (MobileTerminalPreview) -> Bool
) async throws -> MobileTerminalPreview {
    for _ in 0..<maxAttempts {
        if let terminal = store.selectedWorkspace?.terminals.first(where: { $0.id == store.selectedTerminalID }),
           predicate(terminal) {
            return terminal
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let terminal = try #require(store.selectedWorkspace?.terminals.first(where: { $0.id == store.selectedTerminalID }))
    #expect(predicate(terminal))
    return terminal
}

private func assertStyledPrompt(_ terminal: MobileTerminalPreview, suffix: String) throws {
    let expectedLine = suffix.isEmpty ? "red prompt" : "red prompt \(suffix)"
    #expect(terminal.snapshot.renderedVisibleLines.first == expectedLine)
    #expect(terminal.snapshot.cursor.column == expectedLine.count)
    #expect(terminal.snapshot.cursor.row == 0)
    let firstCell = try #require(terminal.snapshot.visibleRows.first?.cells.first)
    #expect(firstCell.style.foreground == MobileTerminalGhosttyColor(red: 204, green: 102, blue: 102))
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
