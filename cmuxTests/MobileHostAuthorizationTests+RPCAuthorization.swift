import CMUXMobileCore
import Foundation
@preconcurrency import Network
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - RPC authorization & auth payload shapes
extension MobileHostAuthorizationTests {
    func testMobileWorkspaceRPCRequiresAuthorization() async {
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:],
            auth: nil
        )

        let result = await MobileHostService.shared.debugAuthorizationError(for: request)

        guard case let .failure(error) = result else {
            return XCTFail("workspace.list should require mobile authorization")
        }
        XCTAssertEqual(error.code, "unauthorized")
    }

    func testMobileHostStatusDoesNotRequireAuthorization() async {
        let request = MobileHostRPCRequest(
            id: "host-status",
            method: "mobile.host.status",
            params: [:],
            auth: nil
        )

        let result = await MobileHostService.shared.debugAuthorizationError(for: request)

        XCTAssertNil(result)
    }

    #if DEBUG
    func testDebugStackAuthTokenPolicyRequiresConfiguredToken() {
        XCTAssertNil(MobileHostDevStackAuthPolicy.normalizedToken("   "))
        XCTAssertFalse(MobileHostDevStackAuthPolicy.authorize(
            providedToken: "cmux-dev-token",
            acceptedToken: nil
        ))
        XCTAssertFalse(MobileHostDevStackAuthPolicy.authorize(
            providedToken: "cmux-dev-token",
            acceptedToken: "other-token"
        ))
        XCTAssertTrue(MobileHostDevStackAuthPolicy.authorize(
            providedToken: " cmux-dev-token ",
            acceptedToken: "cmux-dev-token"
        ))
    }

    func testDebugConfiguredStackAuthTokenAuthorizesBroadWorkspaceList() async {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        defer {
            service.debugConfigureAcceptedStackAuthTokenForTesting(nil)
        }

        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:],
            auth: MobileHostRPCAuth(
                attachToken: nil,
                stackAccessToken: "cmux-dev-token"
            )
        )

        let result = await service.debugAuthorizationError(for: request)

        XCTAssertNil(result)
    }
    #endif

    func testMobileHostRPCRejectsInvalidParamsShape() {
        let data = Data(#"{"id":"bad-params","method":"workspace.list","params":[]}"#.utf8)

        let result = MobileHostRPCEnvelope.decodeRequest(data)

        guard case let .failure(error) = result else {
            return XCTFail("Invalid params shape should be rejected")
        }
        XCTAssertEqual(error.code, "invalid_request")
        XCTAssertEqual(error.message, "params must be an object")
    }

    func testMobileHostRPCRejectsInvalidAuthShape() {
        let data = Data(#"{"id":"bad-auth","method":"workspace.list","auth":"token"}"#.utf8)

        let result = MobileHostRPCEnvelope.decodeRequest(data)

        guard case let .failure(error) = result else {
            return XCTFail("Invalid auth shape should be rejected")
        }
        XCTAssertEqual(error.code, "invalid_request")
        XCTAssertEqual(error.message, "auth must be an object")
    }

    func testMobileHostRPCIgnoresRefreshTokenOnlyAuth() {
        let data = Data(#"{"id":"refresh-only","method":"workspace.list","auth":{"stack_refresh_token":"secret"}}"#.utf8)

        let result = MobileHostRPCEnvelope.decodeRequest(data)

        guard case let .success(request) = result else {
            return XCTFail("Refresh-token-only auth should decode as an unauthenticated request")
        }
        XCTAssertNil(request.auth)
    }

    func testStackUserAuthorizationRequiresSignedInMacUser() throws {
        XCTAssertThrowsError(
            try MobileHostAuthorizationPolicy.authorizeStackUser(
                localUserID: nil,
                remoteUserID: "user_remote"
            )
        )
    }

    func testStackUserAuthorizationRequiresMatchingUser() throws {
        XCTAssertThrowsError(
            try MobileHostAuthorizationPolicy.authorizeStackUser(
                localUserID: "user_local",
                remoteUserID: "user_remote"
            )
        )

        XCTAssertNoThrow(
            try MobileHostAuthorizationPolicy.authorizeStackUser(
                localUserID: "user_local",
                remoteUserID: "user_local"
            )
        )
    }

}
