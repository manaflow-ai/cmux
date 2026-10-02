import CmuxFeedPushCore
import CmuxHomeCore
import CmuxHomeUI
import CmuxiOSAuth
import CmuxiOSPush
import Foundation
import OSLog
import UserNotifications

/// The composition root: built once at launch, owns every long-lived object.
/// No singletons below it; everything is injected.
@MainActor
final class AppContainer {
    let auth: StackAuthGate
    let devOptions: DevOptions
    let push: PushRegistration
    let feedResponder: FeedNotificationResponder
    private let notificationDelegate: NotificationDelegate
    private(set) var home: HomeStore?
    private var homeAccount: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let composition = MobileAuthComposition(
            environment: environment,
            reachability: PathReachability()
        )
        auth = StackAuthGate(composition: composition)
        devOptions = DevOptions(environment: environment)
        // Feed pushes (plans/cmux-next/feed.md 7.3) go through the API Worker as
        // this install. The install principal does not exist on iPhone yet, so
        // ops are refused locally until identity lands (PushRegistration.State.pending).
        let ops = CloudOpsClient(baseURL: Self.cloudAPIBaseURL(), tokens: UnavailableInstallToken())
        #if DEBUG
        let environment: CloudOp.APNsEnvironment = .development
        #else
        let environment: CloudOp.APNsEnvironment = .production
        #endif
        push = PushRegistration(ops: ops, topic: Bundle.main.bundleIdentifier ?? "", environment: environment)
        feedResponder = FeedNotificationResponder(ops: ops)
        notificationDelegate = NotificationDelegate(responder: feedResponder)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        feedResponder.openItem = { item in
            // The feed list is not on iPhone yet; Home stays in front.
            Logger(subsystem: "dev.cmux.ios", category: "push").info("open feed item \(item, privacy: .public)")
        }
    }

    /// `CMUXCloudAPIBaseURL` from Info.plist (set per configuration in the xcconfigs).
    private static func cloudAPIBaseURL() -> URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CMUXCloudAPIBaseURL") as? String ?? ""
        return URL(string: raw.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == "https" ? $0 : nil }
            ?? URL(string: "https://cloud-api-staging.cmux.dev")!
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
    func signedIn() {
        Task { await push.start() }
    }

    func signedOut() {
        Task { await push.signOut() }
        home?.stop()
        home = nil
        homeAccount = nil
    }

    var apiBaseURL: String { auth.composition.config.apiBaseURL }
}
