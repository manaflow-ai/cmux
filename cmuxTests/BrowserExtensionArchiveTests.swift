import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserExtensionArchiveTests {
    @Test func extractsExtensionIDFromStoreLinksOnly() {
        #expect(BrowserExtensionArchive.id(in: "https://chromewebstore.google.com/detail/demo/abcdefghijklmnopabcdefghijklmnop") == "abcdefghijklmnopabcdefghijklmnop")
        #expect(BrowserExtensionArchive.id(in: "zabcdefghijklmnopabcdefghijklmnop") == nil)
    }

    @Test func rejectsNonCRXDataBeforeUnpacking() {
        #expect(throws: BrowserExtensionArchive.Error.invalidCRX) {
            _ = try BrowserExtensionArchive.verifiedZip(
                Data("not a CRX".utf8),
                id: "abcdefghijklmnopabcdefghijklmnop"
            )
        }
    }
}
