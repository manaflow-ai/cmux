import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AppDelegateLaunchDefaultsTests {
    /// Verifies that `applicationWillFinishLaunching` registers the AppKit
    /// autofill heuristic default as `false` before AppKit starts its text-input
    /// heuristics, guarding the macOS 26 respawn-loop fix.
    @Test func willFinishLaunchingRegistersAppKitAutoFillHeuristicDefaultOff() throws {
        let key = "NSAutoFillHeuristicControllerEnabled"
        let defaults = UserDefaults.standard
        let registrationDomain = UserDefaults.registrationDomain
        let persistentDomainName = try #require(Bundle.main.bundleIdentifier)
        let previousPersistentDomain = defaults.persistentDomain(forName: persistentDomainName) ?? [:]
        let previousPersistedValue = previousPersistentDomain[key]
        let previousRegistrationDomain = defaults.volatileDomainNames.contains(registrationDomain)
            ? defaults.volatileDomain(forName: registrationDomain)
            : nil

        defaults.removeObject(forKey: key)
        defaults.removeVolatileDomain(forName: registrationDomain)
        defer {
            defaults.removeObject(forKey: key)
            if let previousPersistedValue {
                defaults.set(previousPersistedValue, forKey: key)
            }
            if let previousRegistrationDomain {
                defaults.setVolatileDomain(previousRegistrationDomain, forName: registrationDomain)
            } else {
                defaults.removeVolatileDomain(forName: registrationDomain)
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let selector = #selector(NSApplicationDelegate.applicationWillFinishLaunching(_:))
        guard appDelegate.responds(to: selector) else {
            Issue.record("AppDelegate should register launch defaults before AppKit starts text-input heuristics")
            return
        }

        let notification = Notification(name: NSApplication.willFinishLaunchingNotification, object: NSApp)
        appDelegate.perform(selector, with: notification)

        #expect(defaults.object(forKey: key) as? Bool == false)
    }
}
