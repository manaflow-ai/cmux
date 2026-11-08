#if DEBUG
import CmuxMobileShell

/// Test-only substitute for the external account revoke. It lets XCUITest drive
/// the production local deletion and root-presentation lifecycle without
/// mutating an account-owned computer binding.
@MainActor
struct SuccessfulComputerForgetUITestStub: MobileIrohMacForgetting {
    func forgetComputer(
        macDeviceID _: String,
        instanceTag _: String?,
        expectedAccountID _: String
    ) async throws {}
}
#endif
