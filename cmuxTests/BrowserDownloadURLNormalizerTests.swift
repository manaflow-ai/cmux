import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Browser download URL normalizer")
struct BrowserDownloadURLNormalizerTests {
    private let normalizer = BrowserDownloadURLNormalizer()

    @Test
    func repeatedPageQueryItemsDoNotTrap() throws {
        let url = try #require(URL(
            string: "https://mail.google.com/mail/u/0/?permmsgid=msg-f:1&permmsgid=msg-f:2"
        ))

        #expect(normalizer.normalize(url) == url)
    }

    @Test
    func caseInsensitiveRedirectQueryCollisionsKeepFirstValue() throws {
        let url = try #require(URL(
            string: "https://www.google.com/url?Url=https://a.example/x&url=https://b.example/y"
        ))

        #expect(normalizer.normalize(url) == URL(string: "https://a.example/x"))
    }
}
