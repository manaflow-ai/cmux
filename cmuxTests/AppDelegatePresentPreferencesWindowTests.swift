import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `AppDelegate.presentPreferencesWindow` seam tests: the shared menu/⌘,
/// entrypoint must route through a result-reporting presenter and must not
/// activate the app when presentation fails
/// (https://github.com/manaflow-ai/cmux/issues/7777). Extracted from
/// `AppDelegateShortcutRoutingTests` to stay within the file-length budget.
@MainActor
final class AppDelegatePresentPreferencesWindowTests: XCTestCase {
    func testPresentPreferencesWindowShowsCustomSettingsWindowAndActivates() {
        var presentSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                presentSettingsWindowCallCount += 1
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(presentSettingsWindowCallCount, 1)
        XCTAssertEqual(activateApplicationCallCount, 1)
        XCTAssertEqual(receivedNavigationTargets, [nil])
    }

    func testPresentPreferencesWindowSupportsRepeatedCalls() {
        var presentSettingsWindowCallCount = 0
        var activateApplicationCallCount = 0
        var receivedNavigationTargets: [SettingsNavigationTarget?] = []

        AppDelegate.presentPreferencesWindow(
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                presentSettingsWindowCallCount += 1
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        AppDelegate.presentPreferencesWindow(
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTargets.append(navigationTarget)
                presentSettingsWindowCallCount += 1
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(presentSettingsWindowCallCount, 2)
        XCTAssertEqual(activateApplicationCallCount, 2)
        XCTAssertEqual(receivedNavigationTargets, [nil, nil])
    }

    func testPresentPreferencesWindowForwardsNavigationTarget() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            navigationTarget: .keyboardShortcuts,
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(receivedNavigationTarget, .keyboardShortcuts)
        XCTAssertEqual(activateApplicationCallCount, 1)
    }

    func testPresentPreferencesWindowForwardsBrowserImportNavigationTarget() {
        var receivedNavigationTarget: SettingsNavigationTarget?
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            navigationTarget: .browserImport,
            presentSettingsWindow: { navigationTarget in
                receivedNavigationTarget = navigationTarget
                return .presented
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(receivedNavigationTarget, .browserImport)
        XCTAssertEqual(activateApplicationCallCount, 1)
    }

    func testPresentPreferencesWindowDoesNotActivateWhenPresentationFails() {
        var activateApplicationCallCount = 0

        AppDelegate.presentPreferencesWindow(
            presentSettingsWindow: { _ in
                .failed(reason: "test-injected presentation failure")
            },
            activateApplication: {
                activateApplicationCallCount += 1
            }
        )

        XCTAssertEqual(
            activateApplicationCallCount, 0,
            "a failed presentation must not silently activate the app as if it succeeded"
        )
    }
}
