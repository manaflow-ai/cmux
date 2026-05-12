import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MobileHostAuthorizationTests: XCTestCase {
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
