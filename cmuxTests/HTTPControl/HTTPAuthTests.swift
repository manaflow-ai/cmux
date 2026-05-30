import Foundation
import Testing
@testable import cmux

@Suite struct HTTPAuthTests {
    private let token = "abcdef0123456789"

    @Test func missingHeaderReportedAsMissing() {
        let auth = HTTPAuth(expectedToken: token)
        #expect(auth.evaluate(authorizationHeader: nil) == .missing)
    }

    @Test func wrongTokenSameLengthRejected() {
        let auth = HTTPAuth(expectedToken: token)
        #expect(auth.evaluate(authorizationHeader: "Bearer ZZZZZZZZZZZZZZZZ") == .invalid)
    }

    @Test func wrongLengthRejected() {
        let auth = HTTPAuth(expectedToken: token)
        // Length mismatch is allowed to leak per threat model — just
        // verify the result is .invalid, not .ok.
        #expect(auth.evaluate(authorizationHeader: "Bearer abc") == .invalid)
        #expect(auth.evaluate(authorizationHeader: "Bearer abcdef0123456789X") == .invalid)
    }

    @Test func wrongSchemeRejected() {
        let auth = HTTPAuth(expectedToken: token)
        #expect(auth.evaluate(authorizationHeader: "Basic abcdef0123456789") == .invalid)
        #expect(auth.evaluate(authorizationHeader: "bearer abcdef0123456789") == .invalid)
    }

    @Test func emptyHeaderRejected() {
        let auth = HTTPAuth(expectedToken: token)
        #expect(auth.evaluate(authorizationHeader: "") == .invalid)
        #expect(auth.evaluate(authorizationHeader: "Bearer ") == .invalid)
    }

    @Test func correctTokenAccepted() {
        let auth = HTTPAuth(expectedToken: token)
        #expect(auth.evaluate(authorizationHeader: "Bearer abcdef0123456789") == .ok)
    }
}
