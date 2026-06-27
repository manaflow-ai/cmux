import CMUXMobileCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileHostInvalidAttachTokenTests {
    @Test func testMobileWorkspaceRPCRejectsInvalidAttachTokenBeforeStackFallback() async {
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:],
            auth: MobileHostRPCAuth(
                attachToken: "missing-attach-token",
                stackAccessToken: nil
            )
        )

        let result = await MobileHostService.shared.debugAuthorizationError(for: request)

        guard case let .failure(error) = result else {
            return #expect(Bool(false), "workspace.list should reject an unknown attach token")
        }
        #expect(error.code == "invalid_attach_token")
    }
}
