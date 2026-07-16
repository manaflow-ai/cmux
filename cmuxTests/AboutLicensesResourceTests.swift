import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("About licenses resources")
struct AboutLicensesResourceTests {
    @Test("The project GPL is available to the About licenses UI")
    func projectLicenseIsBundled() throws {
        let url = try #require(Bundle.main.url(forResource: "LICENSE", withExtension: nil))
        let contents = try String(contentsOf: url, encoding: .utf8)

        #expect(contents.contains("Copyright (c) 2024-present Manaflow, Inc."))
        #expect(contents.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(contents.contains("Version 3, 29 June 2007"))
    }

    @Test("The About licenses content includes the project GPL and source directions")
    func aboutContentIncludesProjectLicenseAndSourceDirections() throws {
        let contents = AboutLicenseContent.load(from: .main)

        #expect(contents.contains("Copyright (c) 2024-present Manaflow, Inc."))
        #expect(contents.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(contents.contains(AboutLicenseContent.repositoryURL.absoluteString))
        #expect(contents.contains(AboutLicenseContent.correspondingSourceURL(in: .main).absoluteString))
    }

    @Test("Stable builds link corresponding source to their exact version tag")
    func stableBuildUsesVersionTag() {
        let url = AboutLicenseContent.correspondingSourceURL(
            version: "0.64.19",
            bundleIdentifier: "com.cmuxterm.app",
            commit: "abcdef123"
        )

        #expect(url.absoluteString == "https://github.com/manaflow-ai/cmux/tree/v0.64.19")
    }

    @Test("Development builds link corresponding source to their commit")
    func developmentBuildUsesCommit() {
        let url = AboutLicenseContent.correspondingSourceURL(
            version: "0.64.19",
            bundleIdentifier: "com.cmuxterm.app.debug.licpkg",
            commit: "abcdef123"
        )

        #expect(url.absoluteString == "https://github.com/manaflow-ai/cmux/tree/abcdef123")
    }
}
