extension StackClientApp {
    /// Resolves both credentials through the shared refresh owner, retaining
    /// cancellation, deadline, and session-replacement failures for callers.
    /// - Parameter forceRefresh: Bypasses cached-token freshness after rejection.
    /// - Returns: A coherent token pair or a classified refresh failure.
    public func resolvedTokenPair(forceRefresh: Bool = false) async -> TokenPair {
        if forceRefresh { return await client.fetchNewAccessToken() }
        return await client.getOrFetchLikelyValidTokens()
    }
}
