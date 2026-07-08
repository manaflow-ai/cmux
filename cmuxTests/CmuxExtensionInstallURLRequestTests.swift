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

    @Test func submissionIssueURLPercentEncodesFieldValues() throws {
        let url = CmuxExtensionSubmitIssueURL.build(
            source: "owner name/repo.with space",
            pinnedSha: "abc 123",
            name: "Name with spaces",
            version: "1.0",
            description: "Line one & line two",
            ref: nil,
            validationOutput: "command: cmux extension submit owner name/repo.with space"
        )
        let absolute = url.absoluteString

        #expect(absolute.contains("repo=owner%20name%2Frepo.with%20space"))
        #expect(absolute.contains("pinned-sha=abc%20123"))
        #expect(absolute.contains("description=Line%20one%20%26%20line%20two"))
        #expect(absolute.contains("validation=command%3A%20cmux%20extension%20submit%20owner%20name%2Frepo.with%20space"))
    }

    @Test func submissionIssueURLIncludesSubdirectoryWhenPresent() throws {
        let url = CmuxExtensionSubmitIssueURL.build(
            source: "owner/repo/examples/tui",
            pinnedSha: "abc123",
            name: "Example",
            version: nil,
            description: nil,
            ref: nil,
            validationOutput: nil
        )
        let queryItems = try queryItems(url)

        #expect(queryItems["template"] == "extension-submission.yml")
        #expect(queryItems["repo"] == "owner/repo")
        #expect(queryItems["subdirectory"] == "examples/tui")
        #expect(queryItems["pinned-sha"] == "abc123")
    }

    @Test func submissionIssueURLOmitsSubdirectoryForRootManifest() throws {
        let url = CmuxExtensionSubmitIssueURL.build(
            source: "owner/repo",
            pinnedSha: "abc123",
            name: "Example",
            version: nil,
            description: nil,
            ref: nil,
            validationOutput: nil
        )
        let queryItems = try queryItems(url)

        #expect(queryItems["repo"] == "owner/repo")
        #expect(queryItems["subdirectory"] == nil)
    }

    @Test func submissionIssueURLUsesIssueFormFieldIdsAndRefInValidation() throws {
        let url = CmuxExtensionSubmitIssueURL.build(
            source: "owner/repo/sub",
            pinnedSha: "abc123",
            name: "Example",
            version: "2.0",
            description: nil,
            ref: "release/v2",
            validationOutput: nil
        )
        let queryItems = try queryItems(url)

        #expect(Set(queryItems.keys).isSuperset(of: [
            "template",
            "repo",
            "subdirectory",
            "pinned-sha",
            "description",
            "validation",
        ]))
        #expect(queryItems["validation"]?.contains("--ref release/v2") == true)
        #expect(queryItems["validation"]?.contains("Version: 2.0") == true)
    }

    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}
