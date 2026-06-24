import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserSSLTrustBypassStateTests {
    @Test
    func failedNavigationRequestMatchRejectsEmptyFailedURL() throws {
        let url = try #require(URL(string: "https://example.internal/submit"))
        let request = URLRequest(url: url)

        #expect(!request.browserMatchesFailedNavigationURLString(""))
    }

    @Test
    func secureConnectionFailedPermitsSSLBypass() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)

        let content = BrowserErrorPageContent(
            error: error,
            failedURL: "https://self-signed.internal"
        )

        #expect(content.permitsSSLBypass)
        #expect(content.message == String(localized: "browser.error.invalidCertificate", defaultValue: "The certificate for this site is invalid."))
    }

    @Test
    func pendingBypassRequiresHTTPSRequest() throws {
        let state = BrowserSSLTrustBypassState()
        let httpURL = try #require(URL(string: "http://example.internal"))
        let fileURL = try #require(URL(string: "file:///tmp/example"))

        #expect(state.createPendingBypassAction(for: URLRequest(url: httpURL)) == nil)
        #expect(state.createPendingBypassAction(for: URLRequest(url: fileURL)) == nil)
    }

    @Test
    func pendingBypassReplaysOriginalRequestOnceAndMarksHostBypassed() throws {
        let state = BrowserSSLTrustBypassState()
        let url = try #require(URL(string: "https://example.internal:8443/submit"))
        let scope = try #require(BrowserSSLTrustScope(url: url))
        let fingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("token=abc123".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let actionURL = try #require(state.createPendingBypassAction(for: request))
        #expect(actionURL.scheme == "cmux-browser-action")
        #expect(actionURL.host == "bypass-ssl")

        let replayed = try #require(state.consumePendingBypassAction(actionURL))
        #expect(replayed.url == url)
        #expect(replayed.httpMethod == "POST")
        #expect(replayed.httpBody == Data("token=abc123".utf8))
        #expect(replayed.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(state.isBypassed(scope: scope, fingerprint: fingerprint))

        let defaultPortURL = try #require(URL(string: "https://example.internal/submit"))
        let defaultPortScope = try #require(BrowserSSLTrustScope(url: defaultPortURL))
        #expect(!state.isBypassed(scope: defaultPortScope, fingerprint: fingerprint))
        #expect(!state.isBypassed(
            scope: scope,
            fingerprint: BrowserServerTrustFingerprint(sha256: Data("leaf-b".utf8))
        ))
        #expect(state.consumePendingBypassAction(actionURL) == nil)
    }

    @Test
    func pendingBypassRejectsMissingForgedAndExpiredTokens() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = BrowserSSLTrustBypassState(tokenLifetime: 10, now: { now })
        let url = try #require(URL(string: "https://expired.internal"))
        let scope = try #require(BrowserSSLTrustScope(url: url))
        let fingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)
        let request = URLRequest(url: url)
        _ = try #require(state.createPendingBypassAction(for: request))

        let missingTokenURL = try #require(URL(string: "cmux-browser-action://bypass-ssl"))
        let forgedTokenURL = try #require(URL(string: "cmux-browser-action://bypass-ssl?token=not-issued"))
        #expect(state.consumePendingBypassAction(missingTokenURL) == nil)
        #expect(state.consumePendingBypassAction(forgedTokenURL) == nil)

        let expiredState = BrowserSSLTrustBypassState(tokenLifetime: -1, now: { now })
        expiredState.recordObservedServerTrustFingerprint(fingerprint, for: scope)
        let expiredActionURL = try #require(expiredState.createPendingBypassAction(for: request))
        #expect(expiredState.consumePendingBypassAction(expiredActionURL) == nil)
        #expect(!expiredState.isBypassed(scope: scope, fingerprint: fingerprint))
    }

    @Test
    func clearingPendingBypassesRejectsPreviouslyIssuedToken() throws {
        let state = BrowserSSLTrustBypassState()
        let url = try #require(URL(string: "https://cleared.internal"))
        let scope = try #require(BrowserSSLTrustScope(url: url))
        let fingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)

        let actionURL = try #require(state.createPendingBypassAction(for: URLRequest(url: url)))
        state.clearPendingBypasses()

        #expect(state.consumePendingBypassAction(actionURL) == nil)
        #expect(!state.isBypassed(scope: scope, fingerprint: fingerprint))
    }

    @Test
    func acceptedBypassGrantsAreBounded() throws {
        let state = BrowserSSLTrustBypassState(maximumPendingBypassCount: 1)
        let firstURL = try #require(URL(string: "https://first.internal"))
        let firstScope = try #require(BrowserSSLTrustScope(url: firstURL))
        let firstFingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        state.recordObservedServerTrustFingerprint(firstFingerprint, for: firstScope)
        let firstActionURL = try #require(state.createPendingBypassAction(for: URLRequest(url: firstURL)))
        _ = try #require(state.consumePendingBypassAction(firstActionURL))

        let secondURL = try #require(URL(string: "https://second.internal"))
        let secondScope = try #require(BrowserSSLTrustScope(url: secondURL))
        let secondFingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-b".utf8))
        state.recordObservedServerTrustFingerprint(secondFingerprint, for: secondScope)
        let secondActionURL = try #require(state.createPendingBypassAction(for: URLRequest(url: secondURL)))
        _ = try #require(state.consumePendingBypassAction(secondActionURL))

        #expect(!state.isBypassed(scope: firstScope, fingerprint: firstFingerprint))
        #expect(state.isBypassed(scope: secondScope, fingerprint: secondFingerprint))
    }

    @Test
    func clearingAllTrustStateRemovesAcceptedGrantsAndObservedFingerprints() throws {
        let state = BrowserSSLTrustBypassState()
        let url = try #require(URL(string: "https://reset.internal"))
        let scope = try #require(BrowserSSLTrustScope(url: url))
        let fingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)
        let actionURL = try #require(state.createPendingBypassAction(for: URLRequest(url: url)))
        _ = try #require(state.consumePendingBypassAction(actionURL))

        state.clearAllTrustState()

        #expect(!state.isBypassed(scope: scope, fingerprint: fingerprint))
        #expect(state.createPendingBypassAction(for: URLRequest(url: url)) == nil)
    }
}
