import CMUXMobileCore
import CmuxMobileAuth
import Foundation
import Observation
import OSLog

public struct CMUXMobileRuntime: Sendable {
    public static let defaultRPCRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    public static let defaultPairingRequestTimeoutNanoseconds: UInt64 = 8 * 1_000_000_000

    public var supportedRouteKinds: [CmxAttachTransportKind]
    public var transportFactory: any CmxByteTransportFactory
    public var stackAccessTokenProvider: @Sendable () async throws -> String
    /// Force-mint a fresh Stack access token, bypassing the cached-token
    /// freshness check. The connection layer calls this exactly once after the
    /// host rejects a request on auth grounds, so the retry presents a genuinely
    /// new credential instead of re-sending the rejected (likely stale) token.
    public var stackAccessTokenForceRefresher: @Sendable () async throws -> String
    public var rpcRequestTimeoutNanoseconds: UInt64
    public var pairingRequestTimeoutNanoseconds: UInt64
    public var now: @Sendable () -> Date
    /// When false, `MobileShellStore` skips background terminal refresh.
    /// Scripted transport tests set this off so background subscribe/poll
    /// requests don't consume responses intended for foreground methods.
    /// Production sets it on (the default), and falls back to the legacy
    /// 750ms poll only when a connected Mac does not support events.
    public var supportsServerPushEvents: Bool

    private static var defaultStackAccessTokenProvider: @Sendable () async throws -> String {
        {
            #if DEBUG
            if let token = MobileShellDevStackAuthTokenProvider.token() {
                return token
            }
            #endif
            return try await AuthManager.shared.getAccessToken()
        }
    }

    private static var defaultStackAccessTokenForceRefresher: @Sendable () async throws -> String {
        {
            #if DEBUG
            // A dev-injected token has no SDK session to refresh; return it as-is
            // so a force-refresh retry still presents the same dev credential.
            if let token = MobileShellDevStackAuthTokenProvider.token() {
                return token
            }
            #endif
            return try await AuthManager.shared.forceRefreshAccessToken()
        }
    }

    public init(
        supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        transportFactory: any CmxByteTransportFactory,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        stackAccessTokenForceRefresher: (@Sendable () async throws -> String)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? Self.defaultStackAccessTokenProvider
        self.stackAccessTokenForceRefresher = stackAccessTokenForceRefresher ?? Self.defaultStackAccessTokenForceRefresher
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.now = now
        self.supportsServerPushEvents = supportsServerPushEvents
    }

    public init(
        transportFactory: any CmxRouteAwareByteTransportFactory,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        stackAccessTokenForceRefresher: (@Sendable () async throws -> String)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true
    ) {
        self.supportedRouteKinds = transportFactory.supportedKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? Self.defaultStackAccessTokenProvider
        self.stackAccessTokenForceRefresher = stackAccessTokenForceRefresher ?? Self.defaultStackAccessTokenForceRefresher
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.supportsServerPushEvents = supportsServerPushEvents
        self.now = now
    }
}

#if DEBUG
enum MobileShellDevStackAuthTokenProvider {
    static let environmentKey = "CMUX_MOBILE_DEV_STACK_AUTH_TOKEN"

    static func token(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let token = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}
#endif
