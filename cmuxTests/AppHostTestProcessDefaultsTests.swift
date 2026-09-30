import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every app-host test process runs the same `cmux DEV` bundle. Its shared
/// preferences domain lives in the runner user's real `~/Library/Preferences`,
/// so without per-process isolation whatever one test process saved (window
/// frame, right sidebar mode and visibility, shortcuts) became the next
/// process's starting state. These tests stand in for "an earlier process" and
/// "a later process" by reading and writing the shared domain directly.
@Suite("App-host test process preferences isolation", .serialized)
struct AppHostTestProcessDefaultsTests {
    private var sharedDomain: CFString {
        (Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) as CFString
    }

    @Test func valueSavedByAnEarlierProcessIsNotVisibleThroughStandardDefaults() {
        let key = "cmux.test.sharedDomainLeak.\(UUID().uuidString)"
        CFPreferencesSetAppValue(key as CFString, "leaked" as CFString, sharedDomain)
        CFPreferencesAppSynchronize(sharedDomain)
        defer {
            CFPreferencesSetAppValue(key as CFString, nil, sharedDomain)
            CFPreferencesAppSynchronize(sharedDomain)
        }

        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    @Test func valueSavedThroughStandardDefaultsStaysOutOfTheSharedDomain() {
        let key = "cmux.test.sharedDomainLeak.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defaults.set("private", forKey: key)
        defer {
            defaults.removeObject(forKey: key)
            CFPreferencesSetAppValue(key as CFString, nil, sharedDomain)
            CFPreferencesAppSynchronize(sharedDomain)
        }
        CFPreferencesAppSynchronize(sharedDomain)

        #expect(defaults.string(forKey: key) == "private")
        #expect(CFPreferencesCopyAppValue(key as CFString, sharedDomain) == nil)
    }
}
