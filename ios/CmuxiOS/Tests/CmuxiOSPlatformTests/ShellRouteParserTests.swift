import CmuxiOSFeatureKit
import CmuxiOSPlatform
import Foundation
import Testing

@Suite("ShellRoute parser")
struct ShellRouteParserTests {
    let parser = ShellRouteParser(bundleScheme: "cmux-ios-dev.cmux.ios.nxc16")

    private func route(_ link: String) -> ShellRoute? { parser.route(for: URL(string: link)!) }

    @Test(arguments: [
        ("cmux://home", ShellRoute.home),
        ("cmux://", .home),
        ("cmux://feed", .feed(item: nil)),
        ("cmux://feed/item_42", .feed(item: "item_42")),
        ("cmux://workspaces", .workspaces),
        ("cmux://workspace/mac-1/ws_abc", .workspace(host: HostID("mac-1"), workspace: "ws_abc", surface: nil)),
        ("cmux://workspace/mac-1/ws_abc/term_9", .workspace(host: HostID("mac-1"), workspace: "ws_abc", surface: "term_9")),
        ("cmux://compose", .compose(host: nil, workspace: nil)),
        ("cmux://compose?host=mac-1&workspace=ws_abc", .compose(host: HostID("mac-1"), workspace: "ws_abc")),
        ("cmux://hosts", .hosts),
        ("cmux://settings", .settings),
        ("cmux://diagnostics", .diagnostics),
        ("cmux://whats-new", .whatsNew),
        ("cmux://search", .search(query: nil)),
        ("cmux://search?q=", .search(query: nil)),
        ("cmux://search?q=api%20deploy", .search(query: "api deploy")),
        ("CMUX://FEED", .feed(item: nil)),
        ("cmux:feed/item_42", .feed(item: "item_42")),
    ])
    func parsesSchemeLinks(link: String, expected: ShellRoute) {
        #expect(route(link) == expected)
    }

    @Test func acceptsBundleSchemeAndUniversalLinks() {
        #expect(route("cmux-ios-dev.cmux.ios.nxc16://feed/x") == .feed(item: "x"))
        #expect(route("https://cmux.com/app/workspace/mac-1/ws_abc") ==
                .workspace(host: HostID("mac-1"), workspace: "ws_abc", surface: nil))
        #expect(route("https://www.cmux.com/app/settings") == .settings)
        #expect(route("https://cmux.com/app") == .home)
    }

    @Test func pairingLinksPassWhole() throws {
        let link = try #require(URL(string: "cmux://pair?ticket=abc"))
        #expect(parser.route(for: link) == .pairing(link))
        let attach = try #require(URL(string: "cmux-ios-dev.cmux.ios.nxc16://attach/xyz"))
        #expect(parser.route(for: attach) == .pairing(attach))
    }

    @Test(arguments: [
        "https://evil.example/app/feed",
        "https://cmux.com/feed",
        "http://cmux.com/app/feed",
        "cmux-ios-other.bundle://feed",
        "mailto:a@b.example",
        "cmux://unknown",
        "cmux://feed/a/b",
        "cmux://home/extra",
        "cmux://search/extra",
        "cmux://workspace/only-host",
        "cmux://workspace/mac/ws%20space",
        "cmux://feed/" + String(repeating: "a", count: 129),
        "cmux://compose?host=bad%2Fhost",
    ])
    func rejectsForeignOrMalformedLinks(link: String) {
        #expect(route(link) == nil)
    }

    @Test func diagnosticsIsTheOnlyAccountFreeRoute() {
        #expect(!ShellRoute.diagnostics.requiresAccount)
        #expect(ShellRoute.feed(item: nil).requiresAccount)
        #expect(ShellRoute.settings.requiresAccount)
    }
}
