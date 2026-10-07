import CmuxiOSSettingsCore
import Foundation
import UIKit
import UserNotifications
import WebKit

/// Erase All Data (e5-extras.md section 3): sign out through the normal
/// owner first (it revokes the install and removes the push target while
/// the session still works), stop sessions, clear process-wide web state,
/// then wipe the plan. The caller shows the final screen.
extension AppContainer {
    /// App Groups in the app's entitlements (cmux.entitlements). Only this
    /// bundle's folder and keys inside them are removed.
    static let appGroupIDs = ["group.dev.cmux.ios"]

    func eraseAllData() async -> EraseReport {
        diagnostics.info("erase", "erase all data")
        await auth.signOut()
        accountLinks.stop()
        await sftp.closeAll()
        let notifications = UNUserNotificationCenter.current()
        notifications.removeAllDeliveredNotifications()
        notifications.removeAllPendingNotificationRequests()
        UIApplication.shared.unregisterForRemoteNotifications()
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        let groups = Self.appGroupIDs.map { id in
            AppGroupContainer(id: id, url: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id))
        }
        let plan = EraseAllDataPlan.standard(bundleID: Bundle.main.bundleIdentifier ?? "", sandbox: .current, groups: groups)
        let report = EraseAllDataExecutor(keychain: SecurityKeychainWiper(), files: FileManagerWiper(), defaults: UserDefaultsWiper())
            .run(plan)
        return report
    }
}
