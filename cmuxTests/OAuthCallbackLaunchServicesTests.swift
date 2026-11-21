import Foundation
import Testing

@Suite("OAuth callback URL ownership")
struct OAuthCallbackLaunchServicesTests {
    @Test("ordinary web URLs remain browser-owned")
    func ordinaryWebURLsRemainBrowserOwned() throws {
        let urlTypes = try loadURLTypes()
        let declaredSchemes = urlTypes.flatMap { type in
            type["CFBundleURLSchemes"] as? [String] ?? []
        }

        #expect(declaredSchemes.allSatisfy { scheme in
            let normalized = scheme.lowercased()
            return normalized != "http" && normalized != "https"
        })
    }

    @Test("the dedicated cmux callback scheme remains declared")
    func dedicatedCallbackSchemeRemainsDeclared() throws {
        let urlTypes = try loadURLTypes()
        let authType = try #require(
            urlTypes.first { $0["CFBundleURLName"] as? String == "$(PRODUCT_BUNDLE_IDENTIFIER).auth" }
        )
        let schemes = try #require(authType["CFBundleURLSchemes"] as? [String])

        #expect(schemes == ["$(CMUX_AUTH_CALLBACK_SCHEME)"])
    }

    private func loadURLTypes() throws -> [[String: Any]] {
        let repoRoot = SwiftTestingAssertions.sourceURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(propertyList as? [String: Any])
        return try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
    }
}
