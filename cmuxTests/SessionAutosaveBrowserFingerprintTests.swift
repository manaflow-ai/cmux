import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A browser-only navigation must change the autosave fingerprint, or the
/// autosave timer skips the save and a crash or force quit restores the
/// browser tab on the page it showed before.
final class SessionAutosaveBrowserFingerprintTests: XCTestCase {
    @MainActor
    func testBrowserNavigationChangesAutosaveFingerprint() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let panel = try XCTUnwrap(workspace.newBrowserSurface(
            inPane: pane,
            url: URL(string: "https://example.com/a"),
            focus: false,
            creationPolicy: .restoration
        ))
        panel.showCloudAddress(try XCTUnwrap(URL(string: "https://example.com/a")))
        let before = manager.sessionAutosaveFingerprint()

        panel.showCloudAddress(try XCTUnwrap(URL(string: "https://example.com/b")))

        XCTAssertNotEqual(
            before,
            manager.sessionAutosaveFingerprint(),
            "a browser navigation must mark the session dirty"
        )
    }

    @MainActor
    func testDockBrowserNavigationChangesAutosaveFingerprint() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let dock = try XCTUnwrap(workspace.dockSplit)
        let panel = BrowserPanel(workspaceId: workspace.id)
        let pane = try XCTUnwrap(dock.bonsplitController.allPaneIds.first)
        dock.panels[panel.id] = panel
        let tabID = try XCTUnwrap(dock.bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: panel.panelType.rawValue,
            isDirty: panel.isDirty,
            inPane: pane
        ))
        dock.bindSurface(tabID, toPanelId: panel.id)
        panel.showCloudAddress(try XCTUnwrap(URL(string: "https://example.com/a")))
        let before = manager.sessionAutosaveFingerprint()
        let dockBefore = dock.sessionBrowserAutosaveFingerprint()

        panel.showCloudAddress(try XCTUnwrap(URL(string: "https://example.com/b")))

        XCTAssertNotEqual(dockBefore, dock.sessionBrowserAutosaveFingerprint())
        XCTAssertNotEqual(before, manager.sessionAutosaveFingerprint(), "a Dock browser navigation must mark the session dirty")
    }

    @MainActor
    func testUnchangedBrowserURLKeepsAutosaveFingerprint() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let panel = try XCTUnwrap(workspace.newBrowserSurface(
            inPane: pane,
            url: URL(string: "https://example.com/a"),
            focus: false,
            creationPolicy: .restoration
        ))
        panel.showCloudAddress(try XCTUnwrap(URL(string: "https://example.com/a")))
        let before = manager.sessionAutosaveFingerprint()

        // Pane visibility and focus changes alone persist nothing new.
        panel.showCloudAddress(try XCTUnwrap(URL(string: "https://example.com/a")))
        _ = panel.preferredURLStringForSessionSnapshot()

        XCTAssertEqual(before, manager.sessionAutosaveFingerprint())
    }
}
