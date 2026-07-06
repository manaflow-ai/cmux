import CMUXAgentLaunch
import XCTest

final class CoderouterEnvironmentPolicyTests: XCTestCase {
    func testClaudeEnabledReturnsAnthropicOverrides() {
        let environment = CoderouterEnvironmentPolicy.environment(
            kind: "claude",
            enabled: true,
            secret: "crk_test",
            gatewayBaseURL: "https://coderouter.cmux.dev"
        )

        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://coderouter.cmux.dev/anthropic")
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], "crk_test")
        XCTAssertEqual(environment.count, 2)
    }

    func testTrailingSlashIsNormalized() {
        let environment = CoderouterEnvironmentPolicy.environment(
            kind: "claude",
            enabled: true,
            secret: "crk_test",
            gatewayBaseURL: "https://coderouter.cmux.dev/"
        )

        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "https://coderouter.cmux.dev/anthropic")
    }

    func testDisabledReturnsEmptyEnvironment() {
        let environment = CoderouterEnvironmentPolicy.environment(
            kind: "claude",
            enabled: false,
            secret: "crk_test",
            gatewayBaseURL: "https://coderouter.cmux.dev"
        )

        XCTAssertEqual(environment, [:])
    }

    func testEmptySecretReturnsEmptyEnvironment() {
        let environment = CoderouterEnvironmentPolicy.environment(
            kind: "claude",
            enabled: true,
            secret: "   ",
            gatewayBaseURL: "https://coderouter.cmux.dev"
        )

        XCTAssertEqual(environment, [:])
    }

    func testEmptyBaseURLReturnsEmptyEnvironment() {
        let environment = CoderouterEnvironmentPolicy.environment(
            kind: "claude",
            enabled: true,
            secret: "crk_test",
            gatewayBaseURL: "   "
        )

        XCTAssertEqual(environment, [:])
    }

    func testNonClaudeKindReturnsEmptyEnvironment() {
        let environment = CoderouterEnvironmentPolicy.environment(
            kind: "codex",
            enabled: true,
            secret: "crk_test",
            gatewayBaseURL: "https://coderouter.cmux.dev"
        )

        XCTAssertEqual(environment, [:])
    }
}
