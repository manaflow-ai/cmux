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
        let licenseContent = AboutLicenseContent(bundle: .main)
        let contents = licenseContent.load()

        #expect(contents.contains("Copyright (c) 2024-present Manaflow, Inc."))
        #expect(contents.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(contents.contains(licenseContent.repositoryURL.absoluteString))
        #expect(contents.contains(licenseContent.correspondingSourceURL().absoluteString))
    }

    @Test("Stable builds link corresponding source to their exact version tag")
    func stableBuildUsesVersionTag() {
        let repositoryURL = URL(string: "https://example.com/cmux-source")!
        let url = AboutLicenseContent(
            bundle: .main,
            repositoryURL: repositoryURL
        ).correspondingSourceURL(
            version: "0.64.19",
            bundleIdentifier: "com.cmuxterm.app",
            commit: "abcdef123"
        )

        #expect(url.absoluteString == "https://example.com/cmux-source/tree/v0.64.19")
    }

    @Test(
        "Non-stable builds link corresponding source to their commit",
        arguments: ["com.cmuxterm.app.debug.licpkg", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"]
    )
    func nonStableBuildUsesCommit(bundleIdentifier: String) {
        let url = AboutLicenseContent(bundle: .main).correspondingSourceURL(
            version: "0.64.19",
            bundleIdentifier: bundleIdentifier,
            commit: "abcdef123"
        )

        #expect(url.absoluteString == "https://github.com/manaflow-ai/cmux/tree/abcdef123")
    }

    /// A temporary app bundle, with the embedded Chromium engine's LICENSE.txt when `cefLicense` is given.
    private func makeBundle(cefLicense: String?) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("about-cef-\(UUID().uuidString)")
        let app = root.appendingPathComponent("T.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.about.cef", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if let cefLicense {
            let resources = contents.appendingPathComponent("Frameworks/Chromium Embedded Framework.framework/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try cefLicense.write(to: resources.appendingPathComponent("LICENSE.txt"), atomically: true, encoding: .utf8)
        }
        return (try #require(Bundle(url: app)), root)
    }

    @Test("A build with the Chromium engine shows CEF's license and where Chromium's credits are")
    func chromiumNoticesWhenEmbedded() throws {
        let (bundle, root) = try makeBundle(cefLicense: "Copyright (c) Marshall A. Greenblatt. BSD license text.")
        defer { try? FileManager.default.removeItem(at: root) }
        let notices = try #require(AboutLicenseContent(bundle: bundle).chromiumNotices())
        #expect(notices.contains("Marshall A. Greenblatt"))
        #expect(notices.contains("chrome://credits"))
        #expect(AboutLicenseContent(bundle: bundle).load().contains("Marshall A. Greenblatt"))
    }

    @Test("A build without the Chromium engine adds no Chromium section")
    func noChromiumNoticesWithoutEngine() throws {
        let (bundle, root) = try makeBundle(cefLicense: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AboutLicenseContent(bundle: bundle).chromiumNotices() == nil)
    }
}
