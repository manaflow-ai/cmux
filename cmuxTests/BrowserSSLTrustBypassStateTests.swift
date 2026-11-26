import CmuxBrowser
import Foundation
import Security
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct BrowserSSLTrustBypassStateTests {
    @Test
    func failedNavigationRequestMatchRejectsEmptyFailedURL() throws {
        let url = try #require(URL(string: "https://example.internal/submit"))
        let request = URLRequest(url: url)

        #expect(!request.browserMatchesFailedNavigationURLString(""))
    }

    @Test
    func failedNavigationRequestMatchNormalizesCommonURLForms() throws {
        let hostOnlyURL = try #require(URL(string: "https://Example.Internal"))
        let hostOnlyRequest = URLRequest(url: hostOnlyURL)
        #expect(hostOnlyRequest.browserMatchesFailedNavigationURLString("https://example.internal/"))

        let defaultPortURL = try #require(URL(string: "https://example.internal:443/path?mode=1#section"))
        let defaultPortRequest = URLRequest(url: defaultPortURL)
        #expect(defaultPortRequest.browserMatchesFailedNavigationURLString("https://example.internal/path?mode=1"))
        #expect(!defaultPortRequest.browserMatchesFailedNavigationURLString("https://example.internal:444/path?mode=1"))
        #expect(!defaultPortRequest.browserMatchesFailedNavigationURLString("https://example.internal/path?mode=2"))
    }

    @Test
    func replayShapeMatchRejectsDifferentMethodAndBody() throws {
        let url = try #require(URL(string: "https://example.internal/submit"))
        var postRequest = URLRequest(url: url)
        postRequest.httpMethod = "POST"
        postRequest.httpBody = Data("confirm=true".utf8)

        var matchingPostRequest = URLRequest(url: url)
        matchingPostRequest.httpMethod = "post"
        matchingPostRequest.httpBody = Data("confirm=true".utf8)
        #expect(matchingPostRequest.browserMatchesReplayShape(of: postRequest))

        let getRequest = URLRequest(url: url)
        #expect(!getRequest.browserMatchesReplayShape(of: postRequest))

        var differentBodyRequest = URLRequest(url: url)
        differentBodyRequest.httpMethod = "POST"
        differentBodyRequest.httpBody = Data("confirm=false".utf8)
        #expect(!differentBodyRequest.browserMatchesReplayShape(of: postRequest))
    }

    @Test
    func replayShapeMatchRequiresSameHeaders() throws {
        let url = try #require(URL(string: "https://example.internal/submit"))
        var request = URLRequest(url: url)
        request.setValue("Bearer token-a", forHTTPHeaderField: "Authorization")

        var matchingRequest = URLRequest(url: url)
        matchingRequest.setValue("Bearer token-a", forHTTPHeaderField: "authorization")
        #expect(matchingRequest.browserMatchesReplayShape(of: request))

        var mismatchedRequest = URLRequest(url: url)
        mismatchedRequest.setValue("Bearer token-b", forHTTPHeaderField: "Authorization")
        #expect(!mismatchedRequest.browserMatchesReplayShape(of: request))
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
    func errorPageRetryURLAllowsOnlyWebURLs() throws {
        let retryURL = try #require(BrowserErrorPage.retryURL(from: "https://self-signed.internal/path"))
        #expect(retryURL.absoluteString == "https://self-signed.internal/path")

        #expect(BrowserErrorPage.retryURL(from: "file:///tmp/cert.html") == nil)
        #expect(BrowserErrorPage.retryURL(from: "cmux-browser-action://bypass-ssl?token=abc") == nil)
        #expect(BrowserErrorPage.retryURL(from: "https:missing-host") == nil)
    }

    @Test
    func errorPageRetryURLRejectsRequestShapesThatNeedReplay() throws {
        let url = try #require(URL(string: "https://self-signed.internal/submit"))

        var postRequest = URLRequest(url: url)
        postRequest.httpMethod = "POST"
        postRequest.httpBody = Data("confirm=true".utf8)
        #expect(BrowserErrorPage.retryURL(from: url.absoluteString, retry: .request(postRequest)) == nil)

        var headerRequest = URLRequest(url: url)
        headerRequest.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        #expect(BrowserErrorPage.retryURL(from: url.absoluteString, retry: .request(headerRequest)) == nil)

        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        #expect(BrowserErrorPage.retryURL(from: url.absoluteString, retry: .request(headRequest)) == nil)

        let getRequest = URLRequest(url: url)
        #expect(BrowserErrorPage.retryURL(from: url.absoluteString, retry: .request(getRequest)) == url)
        #expect(BrowserErrorPage.retryURL(from: url.absoluteString, retry: .disabled) == nil)
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
    func errorPageBypassRequestAllowsURLOnlyHTTPSFailures() throws {
        let state = BrowserSSLTrustBypassState()
        let url = try #require(URL(string: "https://redirected.internal/final"))
        let scope = try #require(BrowserSSLTrustScope(url: url))
        let fingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)

        let request = try #require(BrowserErrorPage.bypassRequest(from: url.absoluteString, retry: .urlOnly))
        #expect(request.url == url)
        #expect((request.httpMethod?.uppercased() ?? "GET") == "GET")
        #expect(request.allHTTPHeaderFields == nil)
        #expect(request.httpBody == nil)
        #expect(request.httpBodyStream == nil)
        #expect(state.createPendingBypassAction(for: request) != nil)
    }

    @Test
    func errorPageBypassRequestRejectsDisabledAndNonWebURLOnlyFailures() throws {
        #expect(BrowserErrorPage.bypassRequest(from: "https://self-signed.internal", retry: .disabled) == nil)
        #expect(BrowserErrorPage.bypassRequest(from: "http://self-signed.internal", retry: .urlOnly) == nil)
        #expect(BrowserErrorPage.bypassRequest(from: "file:///tmp/cert.html", retry: .urlOnly) == nil)
    }

    @Test
    func errorPageDisplayURLIsRestoredWhenLiveInterstitialURLIsBlank() throws {
        let blankURL = try #require(URL(string: "about:blank"))
        let failedURL = try #require(URL(string: "https://self-signed.internal/path"))
        let staleURL = try #require(URL(string: "https://previous.internal/"))

        #expect(BrowserPanel.restorableDisplayURL(
            liveURL: blankURL,
            currentURL: staleURL,
            activeErrorPageDisplayURL: failedURL
        ) == failedURL)

        #expect(BrowserPanel.restorableDisplayURL(
            liveURL: blankURL,
            currentURL: failedURL,
            activeErrorPageDisplayURL: nil
        ) == failedURL)
    }

    @Test
    func pendingBypassRejectsOversizedAndStreamedRequestBodies() throws {
        let url = try #require(URL(string: "https://upload.internal/submit"))
        let scope = try #require(BrowserSSLTrustScope(url: url))
        let fingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        let state = BrowserSSLTrustBypassState(maximumRetainedRequestBodyBytes: 4)
        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)

        var oversizedRequest = URLRequest(url: url)
        oversizedRequest.httpMethod = "POST"
        oversizedRequest.httpBody = Data("12345".utf8)
        #expect(!state.canRetainRequestForReplay(oversizedRequest))
        #expect(state.createPendingBypassAction(for: oversizedRequest) == nil)

        var streamedRequest = URLRequest(url: url)
        streamedRequest.httpMethod = "POST"
        streamedRequest.httpBodyStream = InputStream(data: Data("1234".utf8))
        #expect(!state.canRetainRequestForReplay(streamedRequest))
        #expect(state.createPendingBypassAction(for: streamedRequest) == nil)

        var retainedRequest = URLRequest(url: url)
        retainedRequest.httpMethod = "POST"
        retainedRequest.httpBody = Data("1234".utf8)
        #expect(state.canRetainRequestForReplay(retainedRequest))
        #expect(state.createPendingBypassAction(for: retainedRequest) != nil)
    }

    @Test
    func pendingBypassRejectsBodylessNonIdempotentRequests() throws {
        let url = try #require(URL(string: "https://upload.internal/submit"))
        let scope = try #require(BrowserSSLTrustScope(url: url))
        let fingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        let state = BrowserSSLTrustBypassState()
        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)

        var postRequest = URLRequest(url: url)
        postRequest.httpMethod = "POST"
        #expect(state.createPendingBypassAction(for: postRequest) == nil)

        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        #expect(state.createPendingBypassAction(for: headRequest) != nil)
    }

    @Test
    func newNavigationClearsObservedServerTrustBeforeMintingBypassTokens() throws {
        let state = BrowserSSLTrustBypassState()
        let url = try #require(URL(string: "https://example.internal/submit"))
        let scope = try #require(BrowserSSLTrustScope(url: url))
        let fingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        let request = URLRequest(url: url)

        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)
        #expect(state.createPendingBypassAction(for: request) != nil)

        state.beginObservingServerTrustForNavigation()

        #expect(state.createPendingBypassAction(for: request) == nil)
        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)
        #expect(state.createPendingBypassAction(for: request) != nil)
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

    /// Self-signed P-256 certificate for CN=cmux-trust-fingerprint.test.
    private static let selfSignedLeafDER = Data(base64Encoded: "MIIBozCCAUmgAwIBAgIUERrra7u7YJ5+iX0Y1UWEmPButLswCgYIKoZIzj0EAwIwJjEkMCIGA1UEAwwbY211eC10cnVzdC1maW5nZXJwcmludC50ZXN0MCAXDTI2MTAxMjA1NDQxMloYDzIxMjYwOTE4MDU0NDEyWjAmMSQwIgYDVQQDDBtjbXV4LXRydXN0LWZpbmdlcnByaW50LnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATTVi7oNmfJkC85uk4DJ7sbSRIctQszUX6rBhEGguT1apZ2N3km5lEczGGzPSv7Jfddf9Ip8zJcq+Iwiffssk8yo1MwUTAdBgNVHQ4EFgQUlEb/V7A6Z9L+pRFIe6Db1s4W/0YwHwYDVR0jBBgwFoAUlEb/V7A6Z9L+pRFIe6Db1s4W/0YwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAtha1kN/dbGo81KOQsoSE431MYuLZ5uvUpN+ufq7XkJcCIETBcHrAyirWEqSfzE3YBzpwetZXUMEyVYg30uxplotC")!

    /// #19726: WebKit delivers every server-trust challenge on the main
    /// thread, and fingerprinting a trust evaluates it with a synchronous
    /// trustd round trip that stalled the main thread for seconds. A challenge
    /// with no bypass must not fingerprint; the error page's bypass offer does.
    @Test
    func serverTrustChallengeWithoutBypassDefersFingerprintingToTheErrorPage() throws {
        let url = try #require(URL(string: "https://cmux-trust-fingerprint.test/page"))
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.selfSignedLeafDER as CFData))
        var createdTrust: SecTrust?
        #expect(SecTrustCreateWithCertificates(
            certificate,
            SecPolicyCreateSSL(true, "cmux-trust-fingerprint.test" as CFString),
            &createdTrust
        ) == errSecSuccess)
        let trust = try #require(createdTrust)
        let protectionSpace = URLProtectionSpace(
            host: "cmux-trust-fingerprint.test",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        var fingerprintCount = 0
        let state = BrowserSSLTrustBypassState(fingerprintServerTrust: { serverTrust in
            fingerprintCount += 1
            return BrowserServerTrustFingerprint(serverTrust: serverTrust)
        })

        // What BrowserNavigationDelegate does for each server-trust challenge.
        #expect(!state.isBypassed(protectionSpace: protectionSpace, serverTrust: trust))
        state.recordObservedServerTrust(trust, for: protectionSpace)
        #expect(fingerprintCount == 0)

        let actionURL = try #require(state.createPendingBypassAction(for: URLRequest(url: url)))
        #expect(fingerprintCount == 1)
        _ = try #require(state.consumePendingBypassAction(actionURL))
        #expect(state.isBypassed(protectionSpace: protectionSpace, serverTrust: trust))
    }
}
