import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Supplies an authenticated account for tests that exercise the Cloud menu gate.
///
/// ``AppDelegate`` owns the auth composition, so setting only the Cloud feature
/// flag is insufficient: the production menu gate also requires an authenticated
/// account on ``AppDelegate.shared``. The fixture uses the existing deterministic
/// UI-test auth path and an isolated defaults suite; it never contacts Stack Auth.
@MainActor
final class NewCloudWorkspaceShortcutAuthFixture {
    private let defaults: UserDefaults
    private let suiteName: String
    private let originalAppDelegate: AppDelegate?
    let composition: MacAuthComposition

    init() {
        originalAppDelegate = AppDelegate.shared
        suiteName = "NewCloudWorkspaceShortcutTests.Auth.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        composition = MacAuthComposition(
            environment: [
                "CMUX_UITEST_AUTH_FIXTURE": "1",
                "CMUX_UITEST_AUTH_USER_ID": "new-cloud-workspace-test-user"
            ],
            defaults: defaults
        )
    }

    func makeAppDelegate(authenticated: Bool = true) -> AppDelegate {
        let appDelegate = AppDelegate()
        if authenticated {
            appDelegate.auth = composition
        }
        return appDelegate
    }

    func cleanup() {
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
        AppDelegate.shared = originalAppDelegate
        defaults.removePersistentDomain(forName: suiteName)
    }
}
