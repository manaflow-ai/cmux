public import CmuxiOSOnboardingCore

/// The system permissions onboarding primes. The app passes
/// `SystemPermissionCenter`; previews and tests pass a fake.
@MainActor
public protocol PermissionCenter: AnyObject {
    func status(of kind: PermissionKind) async -> PermissionStatus
    /// Shows the system prompt (when it can still show) and returns the answer.
    func request(_ kind: PermissionKind) async -> PermissionStatus
}
