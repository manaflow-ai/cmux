/// A settable post-sign-in hook used to break the auth-coordinator <-> push
/// construction cycle.
///
/// ``MobileAuthComposition`` builds the ``CmuxAuthRuntime/AuthCoordinator``
/// first (passing `onSignedIn: { await hook.run() }`), then the push service,
/// then points the hook at the push service's token re-upload via ``set(_:)``.
/// Both methods run on the main actor; ``set(_:)`` is called once at
/// construction before any sign-in can fire ``run()``.
@MainActor
final class DeferredSignInHook {
    private var action: (@Sendable () async -> Void)?

    /// Install the hook body. Call once at composition.
    func set(_ action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    /// Run the installed hook (no-op until ``set(_:)`` has been called).
    func run() async {
        await action?()
    }
}
