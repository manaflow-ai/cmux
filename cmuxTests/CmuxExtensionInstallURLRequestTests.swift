import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("CmuxExtensionInstallURLRequest")
struct CmuxExtensionInstallURLRequestTests {
    private let schemes: Set<String> = ["cmux"]

    private func parse(_ string: String) -> Result<CmuxExtensionInstallURLRequest?, CmuxExtensionInstallURLRequest.ParseError> {
        CmuxExtensionInstallURLRequest.parse(URL(string: string)!, supportedSchemes: schemes)
    }

    @Test func parsesRepoRefAndSubdir() throws {
        let simple = try parse("cmux://extensions/install?repo=owner/repo").get()
        #expect(simple?.source == "owner/repo")
        #expect(simple?.ref == nil)

        let pinned = try parse("cmux://extensions/install?repo=owner/repo&ref=v1.2.3").get()
        #expect(pinned?.ref == "v1.2.3")

        let subdir = try parse("cmux://extensions/install?repo=owner/repo&subdir=examples/tui").get()
        #expect(subdir?.source == "owner/repo/examples/tui")

        let inlineSubdir = try parse("cmux://extensions/install?repo=owner/repo/examples/tui").get()
        #expect(inlineSubdir?.source == "owner/repo/examples/tui")
    }

    @Test func otherFamiliesAndSchemesPassThrough() throws {
        // Wrong scheme → not ours.
        #expect(try parse("https://extensions/install?repo=o/r").get() == nil)
        // Same scheme, different host → some other cmux:// family.
        #expect(try parse("cmux://workspace/6EAE0000-0000-4000-8000-000000000001").get() == nil)
        #expect(try parse("cmux://ssh/host").get() == nil)
    }

    @Test func recognizedButMalformedLinksFail() {
        #expect(parse("cmux://extensions/install") == .failure(.missingRepo))
        #expect(parse("cmux://extensions/install?repo=") == .failure(.missingRepo))
        #expect(parse("cmux://extensions/uninstall?repo=o/r") == .failure(.unsupportedURLShape))
        #expect(parse("cmux://extensions/install?repo=o/r&sneaky=1") == .failure(.unsupportedURLShape))
        #expect(parse("cmux://extensions/install?repo=justone") == .failure(.invalidRepo("justone")))
        #expect(parse("cmux://extensions/install?repo=o/r/../evil") == .failure(.invalidRepo("o/r/../evil")))
        #expect(parse("cmux://extensions/install?repo=o/r&ref=bad%20ref") == .failure(.invalidRef("bad ref")))
        #expect(parse("cmux://extensions/install?repo=o/r#frag") == .failure(.unsupportedURLShape))
    }

    @Test func installLinkRoundTrips() throws {
        let link = CmuxExtensionInstallURLRequest.installLink(
            source: "owner/repo/sub",
            ref: "main",
            scheme: "cmux"
        )
        let parsed = try parse(link).get()
        #expect(parsed?.source == "owner/repo/sub")
        #expect(parsed?.ref == "main")
    }
}
