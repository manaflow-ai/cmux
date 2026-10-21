import CmuxHomeCore

/// The Stack access token for the hosted chat server (``HomeWireAuth/stack(_:)``),
/// read through the auth coordinator the composition root owns.
struct StackHomeBearer: HomeBearerProviding {
    /// The coordinator's token read; `true` asks for a refreshed token.
    let token: @Sendable (_ forceRefresh: Bool) async throws -> String

    func accessToken(forceRefresh: Bool) async throws -> String {
        try await token(forceRefresh)
    }
}
