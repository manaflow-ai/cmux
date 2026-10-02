import CmuxHomeCore
import CmuxHomeUI
import CmuxiOSAuth
import Foundation

/// The composition root: built once at launch, owns every long-lived object.
/// No singletons below it; everything is injected.
@MainActor
final class AppContainer {
    let auth: StackAuthGate
    let devOptions: DevOptions
    private(set) var home: HomeStore?
    private var homeAccount: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let composition = MobileAuthComposition(
            environment: environment,
            reachability: PathReachability()
        )
        auth = StackAuthGate(composition: composition)
        devOptions = DevOptions(environment: environment)
    }

    /// The Home store for the signed-in account. Home talks only to a
    /// `HomeSource`; until the Home messaging backend lands this is the mock
    /// owner (plans/cmux-next/ios-rewrite.md, step 5).
    func homeStore(for account: SignedInAccount) -> HomeStore {
        if let home, homeAccount == account.userID { return home }
        home?.stop()
        homeAccount = account.userID
        let store = HomeStore(source: MockHomeSource())
        store.start()
        home = store
        return store
    }

    /// Signing out drops the account's Home mirror.
    func signedOut() {
        home?.stop()
        home = nil
        homeAccount = nil
    }

    var apiBaseURL: String { auth.composition.config.apiBaseURL }
}
