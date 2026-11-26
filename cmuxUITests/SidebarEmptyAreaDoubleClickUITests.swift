import Foundation
import XCTest

/// Double-clicking the sidebar's empty area must create a workspace through the
/// shared new-workspace action, and the workspace must land after the last row.
/// Two sidebar implementations own that gesture — the AppKit list behind
/// `sidebar-appkit-list-experiment` and the SwiftUI `LazyVStack` it replaced —
/// so each one gets driven for real here.
///
/// The unit suite (`SidebarEmptyAreaNewWorkspaceActionTests`) covers what the
/// shared action does — configured `ui.newWorkspace.action` layouts and
/// workspace-group placement — since a UI test cannot point the app at a
/// throwaway `~/.config/cmux/cmux.json`. These tests cover the half the unit
/// suite cannot reach: each gesture handler still routing into that action.
/// Unwiring either call site turns both of them red.
/// https://github.com/manaflow-ai/cmux/issues/10043
final class SidebarEmptyAreaDoubleClickUITests: XCTestCase {
    private let appDefaultsDomain = "com.cmuxterm.app.debug"
    private let appKitSidebarListOverrideKey =
        "cmux.flags.override.sidebar-appkit-list-experiment"
    private let workspaceRowLabelMarker = ", workspace "
    /// Keeps the empty-area click clear of the sidebar footer's account row.
    private let sidebarFooterClearance: CGFloat = 80
    private let appKitSidebarListRemoteKey =
        "cmux.flags.remote.sidebar-appkit-list-experiment"
    private var previousAppKitSidebarListOverride: Any?
    private var previousAppKitSidebarListRemoteValue: Any?
    private var didSetAppKitSidebarListOverride = false

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        restoreAppKitSidebarListOverride()
        super.tearDown()
    }

    func testAppKitSidebarEmptyAreaDoubleClickAppendsWorkspaceAtEnd() throws {
        try runEmptyAreaDoubleClick(appKitSidebarList: true)
    }

    func testSwiftUISidebarEmptyAreaDoubleClickAppendsWorkspaceAtEnd() throws {
        try runEmptyAreaDoubleClick(appKitSidebarList: false)
    }

    // MARK: - Scenario

    /// Parks the selection on the first workspace with the app's placement
    /// preference set to `afterCurrent`, so a workspace appearing last can only
    /// come from the empty area's own `.end` override, never from the default.
    private func runEmptyAreaDoubleClick(appKitSidebarList: Bool) throws {
        overrideAppKitSidebarList(appKitSidebarList)

        let app = XCUIApplication.cmuxTestApplication()
        defer { app.terminate() }
        app.launchArguments += [
            "-newWorkspacePlacement", "afterCurrent",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-NSAppSleepDisabled", "YES",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-empty-area-\(UUID().uuidString.prefix(8))"
        launchAndEnsureRunning(app)
        app.activate()

        XCTAssertTrue(pollUntil(timeout: 20.0) { app.windows.count >= 1 }, "Expected a main window")
        XCTAssertTrue(
            pollUntil(timeout: 20.0) { self.workspaceRows(in: app).count == 1 },
            "Expected the launch workspace row; rows=\(workspaceRowLabels(in: app))"
        )

        // Two more workspaces so "after the selected row" and "after the last
        // row" are different positions. Clicking the titlebar's New Workspace
        // control keeps setup independent of which view owns key focus.
        let newWorkspaceControl = app.descendants(matching: .any)["titlebarControl.newTab"].firstMatch
        XCTAssertTrue(
            newWorkspaceControl.waitForExistence(timeout: 15.0),
            "Expected the titlebar's New Workspace control"
        )
        for expectedCount in 2...3 {
            newWorkspaceControl.click()
            XCTAssertTrue(
                pollUntil(timeout: 15.0) { self.workspaceRows(in: app).count == expectedCount },
                "Expected \(expectedCount) workspace rows; rows=\(workspaceRowLabels(in: app))"
            )
        }

        // Rename the last pre-existing workspace so one row is identifiable by
        // title: with the selection parked on the first row, `afterCurrent`
        // placement would push this row to the bottom, while the empty area's
        // own `.end` placement must leave it where it is.
        let markerTitle = "zeta-marker"
        try renameLastWorkspace(in: app, to: markerTitle)

        let rowsBefore = workspaceRows(in: app)
        XCTAssertEqual(rowsBefore.count, 3, "Expected 3 workspace rows before the gesture")
        XCTAssertEqual(
            rowsBefore.last?.position,
            3,
            "Expected the renamed workspace to be the last row; rows=\(rowsBefore.map(\.label))"
        )

        let firstRow = try XCTUnwrap(rowsBefore.first, "Expected a first workspace row")
        firstRow.element.click()

        try doubleClickSidebarEmptyArea(in: app)

        XCTAssertTrue(
            pollUntil(timeout: 15.0) { self.workspaceRows(in: app).count == rowsBefore.count + 1 },
            "Expected the empty-area double-click to create one workspace; "
                + "rows=\(workspaceRowLabels(in: app))"
        )

        let rowsAfter = workspaceRows(in: app)
        let markerRow = try XCTUnwrap(
            rowsAfter.first { $0.label.hasPrefix(markerTitle) },
            "Expected the renamed workspace to still be listed; rows=\(rowsAfter.map(\.label))"
        )
        XCTAssertEqual(
            markerRow.position,
            rowsBefore.count,
            "The empty area sits below every row, so its workspace lands after the previously "
                + "last row instead of after the selected one; rows=\(rowsAfter.map(\.label))"
        )
        XCTAssertFalse(
            rowsAfter.last?.label.hasPrefix(markerTitle) == true,
            "Expected the created workspace to be the last row; rows=\(rowsAfter.map(\.label))"
        )
    }

    /// Inline-renames the bottom workspace row through its own double-click
    /// rename gesture. Retries the edit: a dropped keystroke leaves a partial
    /// title behind rather than failing the run outright.
    private func renameLastWorkspace(in app: XCUIApplication, to title: String) throws {
        for _ in 1...3 {
            let lastRow = try XCTUnwrap(
                workspaceRows(in: app).last,
                "Expected a workspace row to rename"
            )
            lastRow.element.doubleClick()
            let field = app.textFields.firstMatch
            guard field.waitForExistence(timeout: 10.0) else { continue }
            field.typeKey("a", modifierFlags: [.command])
            field.typeText(title)
            field.typeKey(.return, modifierFlags: [])
            let renamed = pollUntil(timeout: 5.0) {
                self.workspaceRows(in: app).last?.label.hasPrefix(title) == true
            }
            if renamed {
                return
            }
        }
        XCTFail(
            "Expected the renamed title to appear in the sidebar after 3 attempts; "
                + "rows=\(workspaceRowLabels(in: app))"
        )
    }

    // MARK: - Gesture

    /// Double-clicks the strip between the last workspace row and the sidebar
    /// footer, which is the empty area both implementations listen on.
    private func doubleClickSidebarEmptyArea(in app: XCUIApplication) throws {
        let lastRow = try XCTUnwrap(
            workspaceRows(in: app).last,
            "Expected a workspace row to anchor the empty area below"
        )
        let rowFrame = lastRow.element.frame
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10.0), "Expected a main window")
        let emptyAreaY = rowFrame.maxY + rowFrame.height
        XCTAssertLessThan(
            emptyAreaY,
            window.frame.maxY - sidebarFooterClearance,
            "Expected an empty strip below the last workspace row and above the sidebar footer"
        )

        lastRow.element
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: emptyAreaY - rowFrame.midY))
            .doubleClick()
    }

    // MARK: - Sidebar rows

    /// A sidebar row, read from the accessibility label both sidebar
    /// implementations build from `accessibility.workspacePosition`:
    /// `"<title>, workspace <position> of <count>"`.
    private struct WorkspaceRow {
        let element: XCUIElement
        let label: String
        let position: Int
        let count: Int

        /// The selected sidebar row: AppKit reports it as the focused table
        /// cell, SwiftUI as a selected element.
        var isFocused: Bool { element.isSelected || element.value as? Bool == true }
    }

    private func workspaceRows(in app: XCUIApplication) -> [WorkspaceRow] {
        // Query by element type first: a predicate over every descendant makes
        // XCTest walk this app's whole accessibility tree per poll, which is
        // both slow and deep enough to take the automation helper down.
        let matching = NSPredicate(format: "label CONTAINS %@", workspaceRowLabelMarker)
        let candidates = app.cells.matching(matching).allElementsBoundByIndex
        return candidates
            .compactMap { element -> WorkspaceRow? in
                let label = element.label
                guard element.frame.height > 0,
                      let position = Self.workspacePosition(in: label)
                else {
                    return nil
                }
                return WorkspaceRow(
                    element: element,
                    label: label,
                    position: position.position,
                    count: position.count
                )
            }
            .sorted { $0.position < $1.position }
    }

    /// Splits the `", workspace <position> of <count>"` suffix the label ends
    /// with, or nil when the element is not a workspace row.
    private static func workspacePosition(in label: String) -> (position: Int, count: Int)? {
        guard let suffixStart = label.range(of: ", workspace ", options: .backwards) else {
            return nil
        }
        let parts = label[suffixStart.upperBound...].split(separator: " ")
        guard parts.count == 3,
              parts[1] == "of",
              let position = Int(parts[0]),
              let count = Int(parts[2])
        else {
            return nil
        }
        return (position, count)
    }

    private func workspaceRowLabels(in app: XCUIApplication) -> [String] {
        workspaceRows(in: app).map(\.label)
    }

    // MARK: - Feature flag

    /// `CmuxFeatureFlagResolution` gives a cached remote value precedence over a
    /// local override, so a machine that already cached the rollout value would
    /// ignore the override and run the same sidebar in both tests. Park the
    /// cached remote value for the duration of the test and restore it after.
    private func overrideAppKitSidebarList(_ enabled: Bool) {
        guard let defaults = UserDefaults(suiteName: appDefaultsDomain) else {
            XCTFail("Expected the app's defaults domain to be writable")
            return
        }
        previousAppKitSidebarListOverride = defaults.object(forKey: appKitSidebarListOverrideKey)
        previousAppKitSidebarListRemoteValue = defaults.object(forKey: appKitSidebarListRemoteKey)
        didSetAppKitSidebarListOverride = true
        defaults.removeObject(forKey: appKitSidebarListRemoteKey)
        defaults.set(enabled, forKey: appKitSidebarListOverrideKey)
    }

    private func restoreAppKitSidebarListOverride() {
        guard didSetAppKitSidebarListOverride,
              let defaults = UserDefaults(suiteName: appDefaultsDomain) else {
            return
        }
        for (key, value) in [
            (appKitSidebarListOverrideKey, previousAppKitSidebarListOverride),
            (appKitSidebarListRemoteKey, previousAppKitSidebarListRemoteValue),
        ] {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        previousAppKitSidebarListOverride = nil
        previousAppKitSidebarListRemoteValue = nil
        didSetAppKitSidebarListOverride = false
    }

    // MARK: - Waiting

    private func launchAndEnsureRunning(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(
            pollUntil(timeout: 20.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )
    }

    private func pollUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        _ condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() {
                return true
            }
            if ProcessInfo.processInfo.systemUptime - start >= timeout {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }
}
