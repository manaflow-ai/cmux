import Foundation
import Testing
@testable import StackAuth

/// A refresh answered 400 or 401 deletes the stored session only when the answer is about the
/// refresh token (`invalid_grant`, a Stack refresh-token error, or no reason given). An answer that
/// blames the request or the client (a build that sends the wrong client id, secret, project or
/// publishable key) is our bug, not a revoked session: deleting every user's session for it
/// would sign everyone out of a build we then fix forward, and the fix could not bring the
/// sessions back.
@Suite("Refresh rejection: what a 400 or 401 revokes")
struct RefreshRejectionTests {
    private func body(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test("invalid_grant and refresh-token errors revoke the session")
    func refreshTokenRejectionsRevoke() {
        #expect(APIClient.refreshRejectionRevokesSession(statusCode: 400, body: body(["error": "invalid_grant"])))
        #expect(APIClient.refreshRejectionRevokesSession(statusCode: 401, body: body(["error": "invalid_grant"])))
        #expect(APIClient.refreshRejectionRevokesSession(statusCode: 401, body: body(["code": "REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED", "error": "Refresh token not found for this project, or the session has expired/been revoked."])))
    }

    @Test("a 400 or 401 with no readable reason still revokes, as before")
    func unexplainedRejectionsRevoke() {
        #expect(APIClient.refreshRejectionRevokesSession(statusCode: 400, body: Data()))
        #expect(APIClient.refreshRejectionRevokesSession(statusCode: 401, body: Data("<html>nope</html>".utf8)))
        #expect(APIClient.refreshRejectionRevokesSession(statusCode: 400, body: body(["error": "something_new"])))
    }

    @Test("an answer that blames the request or the client keeps the session")
    func clientErrorsKeepTheSession() {
        for error in ["invalid_client", "invalid_request", "unauthorized_client", "unsupported_grant_type", "invalid_scope"] {
            #expect(!APIClient.refreshRejectionRevokesSession(statusCode: 400, body: body(["error": error])), "\(error)")
            #expect(!APIClient.refreshRejectionRevokesSession(statusCode: 401, body: body(["error": error])), "\(error)")
        }
        for code in ["INVALID_OAUTH_CLIENT_ID_OR_SECRET", "PROJECT_NOT_FOUND", "INVALID_PUBLISHABLE_CLIENT_KEY", "CURRENT_PROJECT_NOT_FOUND"] {
            #expect(!APIClient.refreshRejectionRevokesSession(statusCode: 401, body: body(["code": code, "error": "x"])), "\(code)")
        }
    }

    @Test("other statuses never revoke")
    func otherStatusesNeverRevoke() {
        for status in [200, 403, 404, 429, 500, 503] {
            #expect(!APIClient.refreshRejectionRevokesSession(statusCode: status, body: body(["error": "invalid_grant"])), "\(status)")
        }
    }
}
