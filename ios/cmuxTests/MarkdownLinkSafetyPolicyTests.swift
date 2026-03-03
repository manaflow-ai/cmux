import XCTest
@testable import cmux_DEV

final class MarkdownLinkSafetyPolicyTests: XCTestCase {
    func testDefaultPolicyAlwaysConfirms() {
        let policy = MarkdownLinkSafetyPolicy.default
        let url = URL(string: "https://example.com/path")!
        XCTAssertTrue(policy.requiresConfirmation(url: url))
    }

    func testUnsafeOnlyPolicyAllowsExactSafeHost() {
        let policy = MarkdownLinkSafetyPolicy(
            confirmationMode: .unsafeOnly,
            safeSchemes: ["https"],
            safeHosts: ["example.com"],
            safeHostSuffixes: []
        )
        let safeUrl = URL(string: "https://example.com/docs")!
        let unsafeUrl = URL(string: "https://evil.com")!
        XCTAssertFalse(policy.requiresConfirmation(url: safeUrl))
        XCTAssertTrue(policy.requiresConfirmation(url: unsafeUrl))
    }

    func testUnsafeOnlyPolicyAllowsHostSuffix() {
        let policy = MarkdownLinkSafetyPolicy(
            confirmationMode: .unsafeOnly,
            safeSchemes: ["https"],
            safeHosts: [],
            safeHostSuffixes: ["openai.com"]
        )
        let rootUrl = URL(string: "https://openai.com")!
        let subdomainUrl = URL(string: "https://docs.openai.com/guide")!
        let unsafeUrl = URL(string: "https://openai.com.evil.com")!
        XCTAssertFalse(policy.requiresConfirmation(url: rootUrl))
        XCTAssertFalse(policy.requiresConfirmation(url: subdomainUrl))
        XCTAssertTrue(policy.requiresConfirmation(url: unsafeUrl))
    }

    func testUnsafeOnlyPolicyRejectsWrongScheme() {
        let policy = MarkdownLinkSafetyPolicy(
            confirmationMode: .unsafeOnly,
            safeSchemes: ["https"],
            safeHosts: ["example.com"],
            safeHostSuffixes: []
        )
        let httpUrl = URL(string: "http://example.com")!
        XCTAssertTrue(policy.requiresConfirmation(url: httpUrl))
    }
}
