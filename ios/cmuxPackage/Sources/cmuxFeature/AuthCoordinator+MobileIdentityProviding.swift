import CmuxAuthRuntime
import CmuxMobileShellModel

/// Composition-root conformance: the shell reads the signed-in user id straight
/// off the injected ``CmuxAuthRuntime/AuthCoordinator`` through the
/// ``CmuxMobileShellModel/MobileIdentityProviding`` seam, with no forwarding
/// wrapper in between.
///
/// `@retroactive` is appropriate here: both modules live in this repo, and this
/// target is the designated composition root where low-owned protocol seams get
/// their concrete conformers.
extension AuthCoordinator: @retroactive MobileIdentityProviding {
    /// The signed-in Stack user's stable id, or `nil` when signed out.
    public var currentUserID: String? {
        currentUser?.id
    }
}
