import Foundation

/// Bearer tokens for the API Worker.
public protocol CloudCredentials: Sendable {
    func token(for principal: CloudPrincipal) async throws -> String
    /// The Worker refused the token (401): drop any cached copy.
    func invalidate(_ principal: CloudPrincipal) async
}
