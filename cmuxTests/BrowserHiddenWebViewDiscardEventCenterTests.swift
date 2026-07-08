import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class BrowserHiddenWebViewDiscardEventCenterTestSubscriber:
    BrowserHiddenWebViewDiscardEventSubscriber
{
    var policyChanges: [BrowserHiddenWebViewDiscardPolicy.ResolvedPolicy] = []
    var sleepCount = 0
    var wakeCount = 0

    func discardPolicyDidChange(_ policy: BrowserHiddenWebViewDiscardPolicy.ResolvedPolicy) {
        policyChanges.append(policy)
    }

    func systemWillSleep() {
        sleepCount += 1
    }

    func systemDidWake() {
        wakeCount += 1
    }
}

@MainActor
private func withEventCenterTestDefaults(
    _ body: (UserDefaults) throws -> Void
) throws {
    let suiteName = "com.cmux.BrowserHiddenWebViewDiscardEventCenterTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    try body(defaults)
}

@MainActor
@Suite(.serialized)
struct BrowserHiddenWebViewDiscardEventCenterTests {
    @Test func registersOneDefaultsObserverAndOneSleepWakePair() throws {
        try withEventCenterTestDefaults { defaults in
            let eventCenter = BrowserHiddenWebViewDiscardEventCenter(
                defaults: defaults,
                defaultsNotificationCenter: NotificationCenter(),
                workspaceNotificationCenter: NotificationCenter(),
                observerQueue: nil
            )

            let installCount = eventCenter.observerInstallCountForTesting
            #expect(installCount.defaults == 1)
            #expect(installCount.workspace == 2)
        }
    }

    @Test func policyChangeFansOutOnlyForResolvedPolicyChanges() throws {
        try withEventCenterTestDefaults { defaults in
            defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
            defaults.set(300, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            let defaultsCenter = NotificationCenter()
            let eventCenter = BrowserHiddenWebViewDiscardEventCenter(
                defaults: defaults,
                defaultsNotificationCenter: defaultsCenter,
                workspaceNotificationCenter: NotificationCenter(),
                observerQueue: nil
            )
            let subscriber = BrowserHiddenWebViewDiscardEventCenterTestSubscriber()
            eventCenter.add(subscriber)

            defaultsCenter.post(name: UserDefaults.didChangeNotification, object: nil)
            #expect(subscriber.policyChanges.isEmpty)

            defaults.set(false, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
            defaultsCenter.post(name: UserDefaults.didChangeNotification, object: nil)
            defaultsCenter.post(name: UserDefaults.didChangeNotification, object: nil)

            #expect(subscriber.policyChanges.count == 1)
            #expect(subscriber.policyChanges.first?.isEnabled == false)

            defaults.set(120, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            defaultsCenter.post(name: UserDefaults.didChangeNotification, object: nil)

            #expect(subscriber.policyChanges.count == 2)
            #expect(subscriber.policyChanges.last?.hiddenDelay == 120)
        }
    }

    @Test func weakSubscribersArePrunedAfterDeallocation() throws {
        try withEventCenterTestDefaults { defaults in
            let defaultsCenter = NotificationCenter()
            let eventCenter = BrowserHiddenWebViewDiscardEventCenter(
                defaults: defaults,
                defaultsNotificationCenter: defaultsCenter,
                workspaceNotificationCenter: NotificationCenter(),
                observerQueue: nil
            )
            do {
                let subscriber = BrowserHiddenWebViewDiscardEventCenterTestSubscriber()
                eventCenter.add(subscriber)
                #expect(eventCenter.subscriberCountForTesting == 1)
            }

            defaults.set(false, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
            defaultsCenter.post(name: UserDefaults.didChangeNotification, object: nil)

            #expect(eventCenter.subscriberCountForTesting == 0)
        }
    }

    @Test func sleepWakeFanOutWorks() throws {
        try withEventCenterTestDefaults { defaults in
            let workspaceCenter = NotificationCenter()
            let eventCenter = BrowserHiddenWebViewDiscardEventCenter(
                defaults: defaults,
                defaultsNotificationCenter: NotificationCenter(),
                workspaceNotificationCenter: workspaceCenter,
                observerQueue: nil
            )
            let subscriber = BrowserHiddenWebViewDiscardEventCenterTestSubscriber()
            eventCenter.add(subscriber)

            workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

            #expect(subscriber.sleepCount == 1)
            #expect(subscriber.wakeCount == 1)
        }
    }
}
