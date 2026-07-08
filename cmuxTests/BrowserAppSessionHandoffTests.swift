import Foundation
import Testing

@Suite
struct BrowserAppSessionHandoffTests {
    @Test
    func buildsHandoffRequestOnlyForMatchingCmuxOrigin() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let destination = try #require(URL(string: "https://cmux.test/dashboard/billing?tab=plan#current"))

        let handoffRequest = try #require(BrowserAppSessionHandoff.handoffRequest(
            destinationURL: destination,
            webOrigin: origin,
            tokens: BrowserAppSessionTokens(accessToken: "native-access", refreshToken: "native-refresh")
        ))
        let handoffURL = try #require(handoffRequest.url)
        let body = String(data: try #require(handoffRequest.httpBody), encoding: .utf8)
        let components = URLComponents(string: "https://cmux.invalid?\(body ?? "")")
        let form = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(handoffURL.scheme == "https")
        #expect(handoffURL.host == "cmux.test")
        #expect(handoffURL.path == "/handler/app-session-handoff")
        #expect(handoffRequest.httpMethod == "POST")
        #expect(handoffURL.query == nil)
        #expect(form["refresh_token"] == "native-refresh")
        #expect(form["access_token"] == "native-access")
        #expect(form["after"] == "/dashboard/billing?tab=plan#current")
    }

    @Test
    func rejectsOffOriginAndNestedHandoffDestinations() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let offOrigin = try #require(URL(string: "https://example.test/dashboard"))
        let nested = try #require(URL(string: "https://cmux.test/handler/app-session-handoff?after=/dashboard"))

        #expect(BrowserAppSessionHandoff.handoffRequest(
            destinationURL: offOrigin,
            webOrigin: origin,
            tokens: BrowserAppSessionTokens(accessToken: "native-access", refreshToken: "native-refresh")
        ) == nil)
        #expect(BrowserAppSessionHandoff.handoffRequest(
            destinationURL: nested,
            webOrigin: origin,
            tokens: BrowserAppSessionTokens(accessToken: "native-access", refreshToken: "native-refresh")
        ) == nil)
    }

    @Test
    func omitsAccessTokenWhenOnlyRefreshTokenIsAvailable() throws {
        let origin = try #require(URL(string: "http://localhost:3777"))
        let destination = try #require(URL(string: "http://localhost:3777/dashboard"))

        let handoffRequest = try #require(BrowserAppSessionHandoff.handoffRequest(
            destinationURL: destination,
            webOrigin: origin,
            tokens: BrowserAppSessionTokens(accessToken: nil, refreshToken: "native-refresh")
        ))
        let body = String(data: try #require(handoffRequest.httpBody), encoding: .utf8)
        let components = URLComponents(string: "https://cmux.invalid?\(body ?? "")")
        let formNames = Set((components?.queryItems ?? []).map(\.name))

        #expect(formNames.contains("refresh_token"))
        #expect(!formNames.contains("access_token"))
    }

    @Test
    func stackCookieDeletionIsScopedToCmuxOrigin() throws {
        let origin = try #require(URL(string: "https://cmux.test"))
        let projectId = "project-123"

        #expect(BrowserAppSessionHandoff.shouldDeleteCookie(
            name: "stack-access",
            domain: "cmux.test",
            webOrigin: origin,
            projectId: projectId
        ))
        #expect(BrowserAppSessionHandoff.shouldDeleteCookie(
            name: "__Host-stack-refresh-project-123--default",
            domain: ".cmux.test",
            webOrigin: origin,
            projectId: projectId
        ))
        #expect(!BrowserAppSessionHandoff.shouldDeleteCookie(
            name: "stack-access",
            domain: "example.test",
            webOrigin: origin,
            projectId: projectId
        ))
        #expect(!BrowserAppSessionHandoff.shouldDeleteCookie(
            name: "unrelated",
            domain: "cmux.test",
            webOrigin: origin,
            projectId: projectId
        ))
    }
}
