import CmuxFeedPushCore
import CmuxHomeCore
import CmuxHomeUI
import CmuxiOSAuth
import CmuxiOSIdentity
import CmuxiOSPush
import Foundation
import OSLog
import UIKit
import UserNotifications

/// The composition root: built once at launch, owns every long-lived object.
/// No singletons below it; everything is injected.
@MainActor
final class AppContainer {
    let auth: StackAuthGate
    let devOptions: DevOptions
    let push: PushRegistration
    /// The install principal (nil when no API origin is configured).
    let identity: InstallIdentity?
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
        let base = Self.cloudAPIBaseURL()
        let madeIdentity = base.map { InstallIdentity(baseURL: $0, bundleID: Bundle.main.bundleIdentifier ?? "") }
        identity = madeIdentity
        let ops: any CloudOpsSending
        if let base, let madeIdentity {
            ops = CloudOpsClient(baseURL: base, tokens: IdentityTokens(identity: madeIdentity))
        } else {
            ops = DisabledCloudOps()
        }
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

    /// `CMUXCloudAPIBaseURL` from Info.plist (set per configuration in the
    /// xcconfigs). Missing or not https: no ops at all (fail closed), never a
    /// fallback origin that could receive a production credential.
    private static func cloudAPIBaseURL() -> URL? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CMUXCloudAPIBaseURL") as? String ?? ""
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
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
    func signedIn(account: SignedInAccount) {
        let coordinator = auth.coordinator
        let device = UIDevice.current.name
        Task {
            await identity?.signedIn(stackUser: account.userID, deviceName: device,
                                     sessionToken: { @MainActor in try await coordinator.accessToken() })
            await push.start()
        }
    }

    func signedOut() {
        let identity = self.identity
        // Remove the push target while the install token still works, then forget it.
        Task {
            await push.signOut()
            await identity?.signedOut()
        }
        home?.stop()
        home = nil
        homeAccount = nil
    }

    var apiBaseURL: String { auth.composition.config.apiBaseURL }
}

/// Adapts the install principal to the push client's token seam.
struct IdentityTokens: InstallTokenProviding {
    let identity: InstallIdentity
    func installToken() async throws -> String { try await identity.token() }
}
