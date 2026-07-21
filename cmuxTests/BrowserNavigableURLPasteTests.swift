import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserNavigableURLPasteTests {
    private let oauthURL =
        "https://auth.openai.com/oauth/authorize?client_id=app_1234567890" +
        "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback" +
        "&response_type=code&scope=openid%20profile%20email%20offline_access" +
        "&code_challenge=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
        "&code_challenge_method=S256&state=state_abcdefghijklmnopqrstuvwxyz0123456789" +
        "&codex_cli_simplified_flow=true"

    @Test func longOAuthURLNavigatesWithoutRewriting() throws {
        let resolved = try #require(resolveBrowserNavigableURL(oauthURL))

        #expect(resolved.absoluteString == oauthURL)
    }

    @Test func terminalWrappedOAuthURLNavigatesWithoutRewriting() throws {
        let wrapped = oauthURL.replacingOccurrences(of: "&scope=", with: "&\nscope=")
        let resolved = try #require(resolveBrowserNavigableURL(wrapped))

        #expect(resolved.absoluteString == oauthURL)
    }

    @Test func singleLineFieldWrappedOAuthURLNavigatesWithoutSearching() throws {
        // AppKit's single-line field editor converts a pasted newline to a space
        // before Return submits the live field value.
        let fieldValue = oauthURL.replacingOccurrences(of: "&scope=", with: "& scope=")
        let resolved = try #require(resolveBrowserNavigableURL(fieldValue))

        #expect(resolved.absoluteString == oauthURL)
    }

    @Test func surroundingWhitespaceDoesNotRewriteOAuthURL() throws {
        let resolved = try #require(resolveBrowserNavigableURL("  \n\t\(oauthURL)\r\n  "))

        #expect(resolved.absoluteString == oauthURL)
    }

    @Test func URLAndSearchBoundariesRemainStable() throws {
        #expect(try #require(resolveBrowserNavigableURL("localhost:3000")).absoluteString == "http://localhost:3000")
        #expect(
            try #require(resolveBrowserNavigableURL("example.com/path?x=1")).absoluteString ==
                "https://example.com/path?x=1"
        )
        #expect(resolveBrowserNavigableURL("node.js tutorial") == nil)
    }
}
