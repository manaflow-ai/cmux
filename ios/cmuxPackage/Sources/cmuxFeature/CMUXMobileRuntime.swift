import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileRPC
import CmuxMobileSupport
import Foundation
import Observation
import OSLog

public struct CMUXMobileRuntime: Sendable, MobileSyncRuntime {
    public static let defaultRPCRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    public static let defaultPairingRequestTimeoutNanoseconds: UInt64 = 8 * 1_000_000_000
    public static let defaultPairingAttemptTimeoutNanoseconds: UInt64 = 8 * 1_000_000_000

    public var supportedRouteKinds: [CmxAttachTransportKind]
    public var transportFactory: any CmxByteTransportFactory
    public var stackAccessTokenProvider: @Sendable () async throws -> String
    public var stackAccessTokenForStatusProvider: @Sendable () async -> String?
    /// Force-mint a fresh Stack access token, bypassing the cached-token
    /// freshness check. The connection layer calls this exactly once after the
    /// host rejects a request on auth grounds, so the retry presents a genuinely
    /// new credential instead of re-sending the rejected (likely stale) token.
    public var stackAccessTokenForceRefresher: @Sendable () async throws -> String
    public var rpcRequestTimeoutNanoseconds: UInt64
    public var pairingRequestTimeoutNanoseconds: UInt64
    public var pairingAttemptTimeoutNanoseconds: UInt64
    public var now: @Sendable () -> Date
    /// When false, `MobileShellStore` skips background terminal refresh.
    /// Scripted transport tests set this off so background subscribe/poll
    /// requests don't consume responses intended for foreground methods.
    /// Production sets it on (the default), and falls back to the legacy
    /// 750ms poll only when a connected Mac does not support events.
    public var supportsServerPushEvents: Bool
    public var independentEventByteStreamProvider: CmxIndependentEventByteStreamProvider?
    public var terminalLaneProvider: MobileTerminalLaneProvider?
    public var artifactLaneProvider: MobileArtifactLaneProvider?

    /// Builds the production access-token provider over an injected
    /// ``TokenProviding`` (the app-root ``AuthCoordinator``), honoring the DEBUG
    /// environment-token override. Replaces the removed `AuthManager.shared`
    /// reach-in.
    /// - Parameter tokenProvider: The injected token source.
    /// - Returns: A `@Sendable` provider closure for the runtime.
    public static func stackAccessTokenProvider(
        from tokenProvider: any TokenProviding
    ) -> @Sendable () async throws -> String {
        {
            #if DEBUG
            if let token = MobileShellDevStackAuthTokenProvider.token() {
                return token
            }
            #endif
            do {
                return try await tokenProvider.accessToken()
            } catch {
                throw Self.connectionError(forStackAuthError: error)
            }
        }
    }

    public static func stackAccessTokenForStatusProvider(
        from tokenProvider: any TokenProviding
    ) -> @Sendable () async -> String? {
        {
            #if DEBUG
            if let token = MobileShellDevStackAuthTokenProvider.token() {
                return token
            }
            #endif
            return await tokenProvider.storedAccessToken()
        }
    }

    /// Translate a Stack-auth token-fetch error into the RPC layer's connection
    /// error so a transient failure stays retryable.
    ///
    /// ``AuthCoordinator`` throws ``AuthError/networkError``/``AuthError/offline``
    /// when it has no usable access token but a refresh token is still present
    /// (the SDK preserves the refresh token across network/server hiccups), and
    /// ``AuthError/unauthorized`` only when the session is genuinely gone.
    /// ``AuthError/timedOut`` means the token phase hit its own deadline and
    /// maps to ``MobileShellConnectionError/requestTimedOut`` so the pairing/RPC
    /// deadline path handles it as retryable. Other transient failures map to
    /// ``MobileShellConnectionError/connectionClosed`` (retryable, no re-auth
    /// prompt); a definitive failure maps to
    /// ``MobileShellConnectionError/authorizationFailed(_:)`` (drives re-auth).
    /// - Parameter error: The error thrown by the token source.
    /// - Returns: The mapped ``MobileShellConnectionError``.
    static func connectionError(forStackAuthError error: Error) -> MobileShellConnectionError {
        switch error {
        case AuthError.timedOut:
            return .requestTimedOut
        case AuthError.networkError, AuthError.offline:
            return .connectionClosed
        default:
            return .authorizationFailed(
                L10n.string(
                    "mobile.pairing.stackAuthTokenUnavailable",
                    defaultValue: "Sign in on your computer with the same account, then try again."
                )
            )
        }
    }

    /// Builds the production force-refresher over an injected ``TokenProviding``
    /// (the app-root ``AuthCoordinator``), honoring the DEBUG environment-token
    /// override. Replaces the removed `AuthManager.shared` reach-in.
    ///
    /// The connection layer calls this exactly once after the host rejects a
    /// request on auth grounds, so the retry presents a genuinely new credential
    /// instead of re-sending the rejected (likely stale) token.
    /// - Parameter tokenProvider: The injected token source.
    /// - Returns: A `@Sendable` force-refresher closure for the runtime.
    public static func stackAccessTokenForceRefresher(
        from tokenProvider: any TokenProviding
    ) -> @Sendable () async throws -> String {
        {
            #if DEBUG
            // A dev-injected token has no SDK session to refresh; return it as-is
            // so a force-refresh retry still presents the same dev credential.
            if let token = MobileShellDevStackAuthTokenProvider.token() {
                return token
            }
            #endif
            do {
                return try await tokenProvider.forceRefreshAccessToken()
            } catch {
                throw Self.connectionError(forStackAuthError: error)
            }
        }
    }

    public init(
        supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        transportFactory: any CmxByteTransportFactory,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        stackAccessTokenForStatusProvider: (@Sendable () async -> String?)? = nil,
        stackAccessTokenForceRefresher: (@Sendable () async throws -> String)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
        pairingAttemptTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingAttemptTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true,
        independentEventByteStreamProvider: CmxIndependentEventByteStreamProvider? = nil,
        terminalLaneProvider: MobileTerminalLaneProvider? = nil,
        artifactLaneProvider: MobileArtifactLaneProvider? = nil
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? { throw AuthError.unauthorized }
        self.stackAccessTokenForStatusProvider = stackAccessTokenForStatusProvider ?? { nil }
        self.stackAccessTokenForceRefresher = stackAccessTokenForceRefresher ?? { throw AuthError.unauthorized }
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.pairingAttemptTimeoutNanoseconds = pairingAttemptTimeoutNanoseconds
        self.now = now
        self.supportsServerPushEvents = supportsServerPushEvents
        self.independentEventByteStreamProvider = independentEventByteStreamProvider
        self.terminalLaneProvider = terminalLaneProvider
        self.artifactLaneProvider = artifactLaneProvider
    }

    public init(
        transportFactory: any CmxRouteAwareByteTransportFactory,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        stackAccessTokenForStatusProvider: (@Sendable () async -> String?)? = nil,
        stackAccessTokenForceRefresher: (@Sendable () async throws -> String)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultRPCRequestTimeoutNanoseconds,
        pairingRequestTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingRequestTimeoutNanoseconds,
        pairingAttemptTimeoutNanoseconds: UInt64 = CMUXMobileRuntime.defaultPairingAttemptTimeoutNanoseconds,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true,
        independentEventByteStreamProvider: CmxIndependentEventByteStreamProvider? = nil,
        terminalLaneProvider: MobileTerminalLaneProvider? = nil,
        artifactLaneProvider: MobileArtifactLaneProvider? = nil
    ) {
        self.supportedRouteKinds = transportFactory.supportedKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? { throw AuthError.unauthorized }
        self.stackAccessTokenForStatusProvider = stackAccessTokenForStatusProvider ?? { nil }
        self.stackAccessTokenForceRefresher = stackAccessTokenForceRefresher ?? { throw AuthError.unauthorized }
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.pairingAttemptTimeoutNanoseconds = pairingAttemptTimeoutNanoseconds
        self.supportsServerPushEvents = supportsServerPushEvents
        self.independentEventByteStreamProvider = independentEventByteStreamProvider
        self.terminalLaneProvider = terminalLaneProvider
        self.artifactLaneProvider = artifactLaneProvider
        self.now = now
    }
}

#if DEBUG
struct MobileShellDevStackAuthTokenProvider {
    private init() {}

    static let environmentKey = "CMUX_MOBILE_DEV_STACK_AUTH_TOKEN"

    static func token(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let token = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}
#endif
