import Foundation

/// Mutable attempt state is confined to TokenRefreshCoordinator's actor.
final class TokenRefreshAttempt {
    let id = UUID()
    let store: any TokenStoreProtocol
    let refreshToken: String
    let accessToken: String?
    let clock: TokenRefreshClock
    let deadline: UInt64
    var operation: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var waiters: [UUID: AsyncStream<TokenPair>.Continuation] = [:]

    init(store: any TokenStoreProtocol, refreshToken: String, accessToken: String?, clock: TokenRefreshClock, deadline: UInt64) {
        self.store = store
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.clock = clock
        self.deadline = deadline
    }
}
