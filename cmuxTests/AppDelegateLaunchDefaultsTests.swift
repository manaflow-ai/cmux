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
    @Test func willFinishLaunchingRegistersAppKitAutoFillHeuristicDefaultOff() {
        let key = "NSAutoFillHeuristicControllerEnabled"
        let defaults = UserDefaults.standard
        let registrationDomain = UserDefaults.registrationDomain

        // Seed the opposite value for only this key so the assertion proves the
        // delegate registers `false`, rather than passing on a registration the
        // host app already installed at its own launch. `register(defaults:)`
        // merges per key and later registrations win, so this touches no other
        // registered default and stays safe when Swift Testing runs other suites
        // in parallel — unlike wiping the whole registration domain, which would
        // briefly hide every registered default from concurrent tests.
        defaults.register(defaults: [key: true])
        defer { defaults.register(defaults: [key: false]) }

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

        let registered = defaults.volatileDomain(forName: registrationDomain)
        #expect(registered[key] as? Bool == false)
    }
}
