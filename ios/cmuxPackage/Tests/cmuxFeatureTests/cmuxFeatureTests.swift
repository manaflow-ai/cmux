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
// lift; see Packages/CmuxAuthRuntime/Tests.

@Test func mobileRuntimeDefaultsToThirtySecondRPCTimeout() {
    let runtime = CMUXMobileRuntime(
        supportedRouteKinds: [.debugLoopback],
        transportFactory: ScriptedTransportFactory(responses: ScriptedTransportResponses([])),
        stackAccessTokenProvider: { "test-stack-token" }
    )

    #expect(runtime.rpcRequestTimeoutNanoseconds == 30 * 1_000_000_000)
    #expect(runtime.pairingRequestTimeoutNanoseconds == 8 * 1_000_000_000)
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

