import Foundation

/// Decides whether a 400/401 from the refresh-token exchange means the refresh
/// token itself is no longer accepted.
///
/// The token endpoint answers 400/401 for two unrelated reasons. A dead
/// session (expired, revoked, unknown) is `REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED`,
/// or a raw OAuth `invalid_grant`. A rejected client is a different known error
/// on the same statuses: `INVALID_PUBLISHABLE_CLIENT_KEY`,
/// `INVALID_OAUTH_CLIENT_ID_OR_SECRET`, `PUBLISHABLE_CLIENT_KEY_REQUIRED_FOR_PROJECT`,
/// a schema error, or an OAuth `invalid_client` / `invalid_request`. Those say
/// nothing about the user's session: the same refresh token works again once
/// the client or service is fixed, so clearing it would sign the user out for a
/// problem they cannot fix by signing in.
enum RefreshRejection {
    /// Stack known errors that end the session the refresh token belongs to.
    static let sessionEndingKnownErrors: Set<String> = [
        "REFRESH_TOKEN_ERROR",
        "REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED",
        "PROVIDER_REJECTED",
    ]

    /// Whether a refresh response means the refresh token will never work again.
    /// - Parameters:
    ///   - statusCode: The HTTP status of the token endpoint's answer.
    ///   - knownErrorCode: The `x-hexclave-known-error` header, if any.
    ///   - body: The response body.
    /// - Returns: `true` only for a 400/401 that names the refresh token as the
    ///   problem, or that carries no error Stack or OAuth would send at all.
    static func isDefinitive(statusCode: Int, knownErrorCode: String?, body: Data) -> Bool {
        guard statusCode == 400 || statusCode == 401 else { return false }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if let code = nonEmpty(knownErrorCode) ?? nonEmpty(json?["code"] as? String) {
            return sessionEndingKnownErrors.contains(code.uppercased())
        }
        if let oauthError = nonEmpty(json?["error"] as? String) {
            return oauthError == "invalid_grant"
        }
        // No error the service names: keep the long-standing reading of a
        // 400/401 from the token endpoint as a rejected token.
        return true
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
