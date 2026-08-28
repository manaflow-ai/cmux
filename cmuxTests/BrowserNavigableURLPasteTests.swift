import Foundation
import CmuxSettings
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

    @Test func tabWrappedOAuthURLNavigatesWithoutSearching() throws {
        let wrapped = oauthURL.replacingOccurrences(of: "&scope=", with: "&\tscope=")
        let resolved = try #require(resolveBrowserNavigableURL(wrapped))

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

    @Test func allowlistedHostLikeLocalhostInputIsNotRejectedAsAPseudoScheme() throws {
        let resolved = try #require(resolveBrowserNavigableURL("localhost:3000"))
        let policy = BrowserURLAllowlistPolicy(
            managedPatterns: nil,
            userPatterns: ["localhost"]
        )

        #expect(
            TerminalController.browserURLAllowlistBlockedURL(
                rawInput: "localhost:3000",
                resolvedURL: resolved,
                policy: policy
            ) == nil
        )
        #expect(
            TerminalController.browserURLAllowlistBlockedURL(
                rawInput: "https://outside.example",
                resolvedURL: try #require(URL(string: "https://outside.example")),
                policy: policy
            )?.absoluteString == "https://outside.example"
        )
    }

    @Test func localFileBrowserAutomationUsesTheTrustedAllowlistPath() throws {
        let fileURL = try #require(URL(string: "file:///tmp/cmux-report.html"))
        let policy = BrowserURLAllowlistPolicy(
            managedPatterns: nil,
            userPatterns: ["localhost"]
        )

        #expect(
            TerminalController.browserURLAllowlistBlockedURL(
                rawInput: fileURL.absoluteString,
                resolvedURL: fileURL,
                policy: policy
            ) == nil
        )
    }

    @Test func automationAllowlistKeepsArbitraryDataURLsBlocked() throws {
        let dataURL = try #require(URL(string: "data:text/html,not-a-cmux-document"))
        let policy = BrowserURLAllowlistPolicy(managedPatterns: [])

        #expect(
            TerminalController.browserURLAllowlistBlockedURL(
                rawInput: dataURL.absoluteString,
                resolvedURL: dataURL,
                policy: policy
            )?.absoluteString == dataURL.absoluteString
        )
    }

    @Test func browserTabAutomationResolvesHostLikeLocalhostInput() throws {
        let resolved = try #require(
            TerminalController.browserAutomationURL(from: " localhost:3000 ")
        )
        #expect(resolved.absoluteString == "http://localhost:3000")
    }

    @Test func bareAbsolutePathNavigatesAsLocalFileURL() throws {
        let resolved = try #require(resolveBrowserNavigableURL("/Users/x/y.html"))

        #expect(resolved.isFileURL)
        #expect(resolved.path == "/Users/x/y.html")
    }
}
