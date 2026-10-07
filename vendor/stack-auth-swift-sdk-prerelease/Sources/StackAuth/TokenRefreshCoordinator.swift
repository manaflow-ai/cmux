import Foundation

/// Shares one exchange and its failure across callers of the same token store.
/// The SDK already shares stores across StackClientApp instances; this registry
/// preserves that ownership boundary without serially retrying every waiter.
actor TokenRefreshCoordinator {
    private var attempts: [ObjectIdentifier: TokenRefreshAttempt] = [:]

    func resolve(
        store: any TokenStoreProtocol,
        refreshToken: String,
        accessToken: String?,
        clock: TokenRefreshClock,
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async -> APIClient.RefreshOutcome
    ) async -> TokenPair {
        guard !Task.isCancelled else { return failed(.cancelled) }
        let storedAccess = await store.getStoredAccessToken()
        guard await store.getStoredRefreshToken() == refreshToken else { return failed(.sessionChanged) }
        guard !Task.isCancelled else { return failed(.cancelled) }
        let key = ObjectIdentifier(store)
        if attempts[key] == nil, storedAccess != accessToken, !isTokenExpired(storedAccess) {
            return TokenPair(refreshToken: refreshToken, accessToken: storedAccess)
        }
        if let previous = attempts[key], previous.refreshToken != refreshToken {
            end(key, id: previous.id, result: failed(.sessionChanged))
        }
        let attempt: TokenRefreshAttempt
        if let existing = attempts[key] {
            attempt = existing
        } else {
            attempt = TokenRefreshAttempt(
                store: store, refreshToken: refreshToken, accessToken: accessToken,
                clock: clock, deadline: clock.now() &+ timeoutNanoseconds
            )
            attempts[key] = attempt
            let id = attempt.id
            let deadline = attempt.deadline
            attempt.operation = Task { [weak self] in
                let outcome = await operation()
                await self?.complete(key, id: id, outcome: outcome)
            }
            attempt.timer = Task { [weak self] in
                do { try await clock.sleepUntil(deadline) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.end(key, id: id, result: TokenPair(refreshToken: nil, accessToken: nil, refreshFailure: .timedOut))
            }
        }
        let waiterID = UUID()
        let id = attempt.id
        let stream = AsyncStream<TokenPair> { continuation in
            attempt.waiters[waiterID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeWaiter(key, id: id, waiterID: waiterID) }
            }
        }
        for await result in stream {
            removeWaiter(key, id: id, waiterID: waiterID)
            return Task.isCancelled ? failed(.cancelled) : result
        }
        removeWaiter(key, id: id, waiterID: waiterID)
        return failed(.cancelled)
    }

    func tokensDidChange(store: any TokenStoreProtocol, refreshToken: String?) {
        let key = ObjectIdentifier(store)
        guard let attempt = attempts[key], attempt.refreshToken != refreshToken else { return }
        end(key, id: attempt.id, result: failed(.sessionChanged))
    }

    private func complete(_ key: ObjectIdentifier, id: UUID, outcome: APIClient.RefreshOutcome) async {
        guard let attempt = attempts[key], attempt.id == id else { return }
        guard attempt.clock.now() < attempt.deadline else {
            end(key, id: id, result: failed(.timedOut))
            return
        }
        guard await attempt.store.getStoredRefreshToken() == attempt.refreshToken else {
            end(key, id: id, result: failed(.sessionChanged))
            return
        }
        guard attempts[key]?.id == id, !Task.isCancelled else { return }
        guard attempt.clock.now() < attempt.deadline else {
            end(key, id: id, result: failed(.timedOut))
            return
        }
        let result: TokenPair
        switch outcome {
        case .success(let access):
            await attempt.store.compareAndSet(compareRefreshToken: attempt.refreshToken,
                newRefreshToken: attempt.refreshToken, newAccessToken: access)
            result = TokenPair(refreshToken: attempt.refreshToken, accessToken: access)
        case .definitivelyRejected:
            await attempt.store.compareAndSet(compareRefreshToken: attempt.refreshToken,
                newRefreshToken: nil, newAccessToken: nil)
            result = TokenPair(refreshToken: nil, accessToken: nil)
        case .transientFailure:
            result = TokenPair(refreshToken: attempt.refreshToken,
                accessToken: nil)
        }
        // compareAndSet prevents stale writes; this guard also prevents returning
        // a token whose compare-and-set lost to sign-out or account replacement.
        let expectedRefresh = result.refreshToken
        guard await attempt.store.getStoredRefreshToken() == expectedRefresh else {
            end(key, id: id, result: failed(.sessionChanged))
            return
        }
        end(key, id: id, result: attempt.clock.now() < attempt.deadline ? result : failed(.timedOut))
    }

    private func removeWaiter(_ key: ObjectIdentifier, id: UUID, waiterID: UUID) {
        guard let attempt = attempts[key], attempt.id == id else { return }
        attempt.waiters[waiterID] = nil
        if attempt.waiters.isEmpty { end(key, id: id, result: failed(.cancelled)) }
    }

    private func end(_ key: ObjectIdentifier, id: UUID, result: TokenPair) {
        guard let attempt = attempts[key], attempt.id == id else { return }
        attempts[key] = nil
        attempt.operation?.cancel()
        attempt.timer?.cancel()
        for waiter in attempt.waiters.values { waiter.yield(result); waiter.finish() }
        attempt.waiters = [:]
    }

    private nonisolated func failed(_ failure: TokenRefreshFailure) -> TokenPair {
        TokenPair(refreshToken: nil, accessToken: nil, refreshFailure: failure)
    }
}
