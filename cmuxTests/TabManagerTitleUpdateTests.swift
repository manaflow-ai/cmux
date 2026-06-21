import Foundation
import XCTest
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@discardableResult
private func waitForTitleCondition(
    timeout: TimeInterval = 3.0,
    pollInterval: TimeInterval = 0.05,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
) -> Bool {
    if condition() {
        return true
    }

    let expectation = XCTestExpectation(description: "wait for title condition")
    let deadline = Date().addingTimeInterval(timeout)

    func poll() {
        if condition() {
            expectation.fulfill()
            return
        }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            poll()
        }
    }

    DispatchQueue.main.async {
        poll()
    }

    let result = XCTWaiter().wait(for: [expectation], timeout: timeout + pollInterval + 0.1)
    if result != .completed {
        XCTFail("Timed out waiting for title condition", file: file, line: line)
        return false
    }
    return true
}

@MainActor
final class TabManagerTitleUpdateTests: XCTestCase {
    func testCoalescerReschedulesWhenDelayChangesMidBurst() {
        let coalescer = NotificationBurstCoalescer(delay: 0.02)
        let flushed = XCTestExpectation(description: "flush after updated delay")
        var flushCount = 0

        coalescer.signal {
            flushCount += 1
            flushed.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
            coalescer.signal(delay: 0.25) {
                flushCount += 1
                flushed.fulfill()
            }
        }

        let oldDelayWindowPassed = XCTestExpectation(description: "old delay window passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            oldDelayWindowPassed.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [oldDelayWindowPassed], timeout: 1.0), .completed)
        XCTAssertEqual(flushCount, 0)
        XCTAssertEqual(XCTWaiter().wait(for: [flushed], timeout: 1.0), .completed)
        XCTAssertEqual(flushCount, 1)
    }

    func testTitleCoalescingDelayUsesCurrentSettingsAtNotificationTime() throws {
        let suiteName = "TabManagerTitleCoalescingSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let manager = TabManager(settings: settings)
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(300, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Runtime Delay - grok"
            ]
        )

        let earlyFlush = XCTestExpectation(description: "wait before configured coalescing delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            earlyFlush.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [earlyFlush], timeout: 1.0), .completed)
        XCTAssertNotEqual(workspace.panelTitles[focusedPanelId], "Runtime Delay - grok")
        XCTAssertNotEqual(workspace.title, "Runtime Delay - grok")

        XCTAssertTrue(
            waitForTitleCondition(timeout: 1.0) {
                workspace.panelTitles[focusedPanelId] == "Runtime Delay - grok" &&
                    workspace.title == "Runtime Delay - grok"
            }
        )
    }

    func testTitleNotificationIgnoredWhenWorkspaceIsNotOwnedByManager() throws {
        let suiteName = "TabManagerTitleOwnership.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(100, for: catalog.terminal.titleUpdateCoalescingMilliseconds)

        let manager = TabManager(settings: settings)
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let originalPanelTitle = workspace.panelTitles[focusedPanelId]

        XCTAssertTrue(workspace.owningTabManager === manager)
        workspace.owningTabManager = nil
        defer { workspace.owningTabManager = manager }

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: focusedPanelId,
                GhosttyNotificationKey.title: "Ignored Non Owner - grok"
            ]
        )

        let delayedFlush = XCTestExpectation(description: "wait past configured title coalescing delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            delayedFlush.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [delayedFlush], timeout: 1.0), .completed)
        XCTAssertEqual(workspace.panelTitles[focusedPanelId], originalPanelTitle)
        XCTAssertNotEqual(workspace.panelTitles[focusedPanelId], "Ignored Non Owner - grok")
        XCTAssertNotEqual(workspace.title, "Ignored Non Owner - grok")
    }

    func testTitleCoalescingDelayIsDefaultOffAndClampedWhenEnabled() throws {
        let suiteName = "TabManagerTitleCoalescingClamp.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()

        settings.set(1_000, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        XCTAssertEqual(
            PanelTitleUpdateCoalescingSettings.delay(settings: settings),
            PanelTitleUpdateCoalescingSettings.defaultDelay,
            accuracy: 0.000_1
        )

        settings.set(true, for: catalog.terminal.titleUpdateCoalescingEnabled)
        settings.set(1, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        XCTAssertEqual(PanelTitleUpdateCoalescingSettings.delay(settings: settings), 0.033, accuracy: 0.000_1)

        settings.set(10_000, for: catalog.terminal.titleUpdateCoalescingMilliseconds)
        XCTAssertEqual(PanelTitleUpdateCoalescingSettings.delay(settings: settings), 5.0, accuracy: 0.000_1)
    }
}
