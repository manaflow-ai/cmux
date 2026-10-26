import Foundation

/// Reads a 400/401 from the refresh-token exchange: does it end the session the
/// refresh token belongs to, or reject the request for another reason?
///
/// The token endpoint answers 400/401 for two unrelated reasons. A dead
/// session (expired, revoked, unknown) is `REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED`,
/// or a raw OAuth `invalid_grant`. A rejected client is a different known error
/// on the same statuses: `INVALID_PUBLISHABLE_CLIENT_KEY`,
/// `INVALID_OAUTH_CLIENT_ID_OR_SECRET`, `PUBLISHABLE_CLIENT_KEY_REQUIRED_FOR_PROJECT`,
/// a schema error, or an OAuth `invalid_client` / `invalid_request`. Those say
/// nothing about the user's session: the same refresh token works again once
/// the client or service is fixed, so clearing it would sign the user out for a
/// problem they cannot fix by signing in. A body that is not JSON (a captive
/// portal or proxy page) did not come from Stack and is no verdict either.
enum RefreshRejection: Equatable {
    /// The refresh token will never work again.
    case sessionEnded
    /// The request was refused for a reason other than the refresh token.
    /// `code` is the known error or OAuth error, when the answer names one.
    case requestRejected(code: String?)

    /// Stack known errors that end the session the refresh token belongs to.
    static let sessionEndingKnownErrors: Set<String> = [
        "REFRESH_TOKEN_ERROR",
        "REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED",
        "PROVIDER_REJECTED",
    ]

    /// Classifies a refresh answer.
    /// - Parameters:
    ///   - statusCode: The HTTP status of the token endpoint's answer.
    ///   - knownErrorCode: The `x-hexclave-known-error` header, if any.
    ///   - body: The response body.
    /// - Returns: `nil` when the status is not 400/401; otherwise
    ///   ``sessionEnded`` only for an answer that names the refresh token, or
    ///   names nothing at all in an empty or JSON body.
    static func classify(statusCode: Int, knownErrorCode: String?, body: Data) -> RefreshRejection? {
        guard statusCode == 400 || statusCode == 401 else { return nil }
        var json: [String: Any]?
        if !body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return .requestRejected(code: nonEmpty(knownErrorCode))
            }
            json = object
        }
        if let code = nonEmpty(knownErrorCode) ?? nonEmpty(json?["code"] as? String) {
            return sessionEndingKnownErrors.contains(code.uppercased()) ? .sessionEnded : .requestRejected(code: code)
        }
        if let oauthError = nonEmpty(json?["error"] as? String) {
            return oauthError == "invalid_grant" ? .sessionEnded : .requestRejected(code: oauthError)
        }
        // A Stack answer that names no error: keep the long-standing reading
        // of a 400/401 from the token endpoint as a rejected token.
        return .sessionEnded
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
