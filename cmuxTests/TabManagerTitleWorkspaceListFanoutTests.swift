import XCTest
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@discardableResult
private func waitForTitleFanoutCondition(
    timeout: TimeInterval = 3.0,
    pollInterval: TimeInterval = 0.05,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
) -> Bool {
    if condition() {
        return true
    }

    let expectation = XCTestExpectation(description: "wait for title fanout condition")
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
        XCTFail("Timed out waiting for condition", file: file, line: line)
        return false
    }
    return true
}

@MainActor
final class TabManagerTitleWorkspaceListFanoutTests: XCTestCase {
    func testTitleWorkspaceListFanoutCanBeDisabled() throws {
        let suiteName = "cmux-title-workspace-list-fanout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(false, for: SettingCatalog().terminal.titleUpdateWorkspaceListFanoutEnabled)

        let manager = TabManager(settings: settings)
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let originalTitle = workspace.title

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: panelId,
                GhosttyNotificationKey.title: "Runtime title"
            ]
        )

        XCTAssertTrue(
            waitForTitleFanoutCondition(timeout: 1.0) {
                workspace.panelTitles[panelId] == "Runtime title" &&
                    workspace.sessionSnapshot(includeScrollback: false).processTitle == "Runtime title"
            }
        )
        XCTAssertEqual(workspace.title, originalTitle)
        XCTAssertNil(workspace.customTitle)
    }
}
