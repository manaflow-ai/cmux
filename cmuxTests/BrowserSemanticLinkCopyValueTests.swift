import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct BrowserSemanticLinkCopyValueTests {
    @Test(arguments: [
        ("mailto:foo@bar.com?subject=Hello&body=World", BrowserSemanticLinkCopyValue.Kind.emailAddress, "foo@bar.com"),
        ("MAILTO:foo%2Btag@example.com?subject=A%20B", BrowserSemanticLinkCopyValue.Kind.emailAddress, "foo+tag@example.com"),
        ("mailto:a@x.com,b@y.com?cc=c@y.com", BrowserSemanticLinkCopyValue.Kind.emailAddress, "a@x.com,b@y.com"),
        ("mailto:a%40x.com,%20b%40y.com?subject=Team", BrowserSemanticLinkCopyValue.Kind.emailAddress, "a@x.com,b@y.com"),
        ("tel:+1%20555%20123%204567", BrowserSemanticLinkCopyValue.Kind.phoneNumber, "+1 555 123 4567"),
        ("TEL:%2B81%203%201234%205678?ignored=true", BrowserSemanticLinkCopyValue.Kind.phoneNumber, "+81 3 1234 5678"),
        ("tel:*67#", BrowserSemanticLinkCopyValue.Kind.phoneNumber, "*67#"),
    ])
    func extractsSemanticCopyValue(
        rawURL: String,
        expectedKind: BrowserSemanticLinkCopyValue.Kind,
        expectedString: String
    ) throws {
        let url = try #require(URL(string: rawURL))
        let value = try #require(BrowserSemanticLinkCopyValue(linkURL: url))

        #expect(value.kind == expectedKind)
        #expect(value.string == expectedString)
    }

    @Test(arguments: [
        "https://example.com/contact",
        "mailto:",
        "mailto:?subject=MissingRecipient",
        "mailto:not-an-email",
        "mailto:a@example.com,",
        "tel:",
        "tel:not-a-number",
    ])
    func ignoresLinksWithoutSemanticCopyValue(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))

        #expect(BrowserSemanticLinkCopyValue(linkURL: url) == nil)
    }
}
