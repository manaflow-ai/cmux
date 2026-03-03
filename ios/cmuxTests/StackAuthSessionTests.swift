import XCTest
@testable import cmux_DEV

final class StackAuthSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AuthUserCache.shared.clear()
        AuthSessionCache.shared.clear()
    }

    override func tearDown() {
        AuthUserCache.shared.clear()
        AuthSessionCache.shared.clear()
        super.tearDown()
    }

    func testAuthLaunchConfigReturnsCredentialsWhenProvided() {
        let environment = [
            "CMUX_UITEST_STACK_EMAIL": "test@example.com",
            "CMUX_UITEST_STACK_PASSWORD": "pass123"
        ]

        let credentials = AuthLaunchConfig.autoLoginCredentials(
            from: environment,
            clearAuth: false,
            mockDataEnabled: false
        )

        XCTAssertEqual(credentials, AuthAutoLoginCredentials(email: "test@example.com", password: "pass123"))
    }

    func testAuthLaunchConfigReturnsNilWhenDisabled() {
        let environment = [
            "CMUX_UITEST_STACK_EMAIL": "test@example.com",
            "CMUX_UITEST_STACK_PASSWORD": "pass123"
        ]

        let cleared = AuthLaunchConfig.autoLoginCredentials(
            from: environment,
            clearAuth: true,
            mockDataEnabled: false
        )
        XCTAssertNil(cleared)

        let mocked = AuthLaunchConfig.autoLoginCredentials(
            from: environment,
            clearAuth: false,
            mockDataEnabled: true
        )
        XCTAssertNil(mocked)
    }

    func testAuthLaunchConfigReturnsNilWhenMissingValues() {
        let noEmail = AuthLaunchConfig.autoLoginCredentials(
            from: ["CMUX_UITEST_STACK_PASSWORD": "pass123"],
            clearAuth: false,
            mockDataEnabled: false
        )
        XCTAssertNil(noEmail)

        let noPassword = AuthLaunchConfig.autoLoginCredentials(
            from: ["CMUX_UITEST_STACK_EMAIL": "test@example.com"],
            clearAuth: false,
            mockDataEnabled: false
        )
        XCTAssertNil(noPassword)
    }

    func testAuthMagicLinkCodeComposition() {
        let combined = AuthMagicLinkCode.compose(code: "123456", nonce: "nonce")
        XCTAssertEqual(combined, "123456nonce")
    }

    func testAuthUserCacheRoundTrip() {
        let user = StackAuthUser(id: "user_123", primaryEmail: "user@example.com", displayName: "Test User")
        AuthUserCache.shared.save(user)
        let loaded = AuthUserCache.shared.load()
        XCTAssertEqual(loaded, user)

        AuthUserCache.shared.clear()
        XCTAssertNil(AuthUserCache.shared.load())
    }

    func testAuthSessionCacheRoundTrip() {
        XCTAssertFalse(AuthSessionCache.shared.hasTokens)
        AuthSessionCache.shared.setHasTokens(true)
        XCTAssertTrue(AuthSessionCache.shared.hasTokens)
        AuthSessionCache.shared.clear()
        XCTAssertFalse(AuthSessionCache.shared.hasTokens)
    }
}
