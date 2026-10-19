import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A tab rename reaches `cmux events` from every entry point, because the
/// shared title action publishes `surface.renamed`. Before this, only the
/// socket's own `surface.action` echo existed, so a name typed into the tab was
/// invisible to watchers (#18692).
@MainActor
final class SurfaceRenamedEventTests: XCTestCase {
    private var subscription: CmuxEventSubscription?

    override func setUp() {
        super.setUp()
        CmuxEventBus.shared.resetForTesting()
        subscription = CmuxEventBus.shared.subscribe(
            afterSequence: nil,
            names: ["surface.renamed"],
            categories: []
        ).subscription
    }

    override func tearDown() {
        if let subscription {
            CmuxEventBus.shared.unsubscribe(subscription)
        }
        subscription = nil
        CmuxEventBus.shared.resetForTesting()
        super.tearDown()
    }

    private func nextEvent(timeout: TimeInterval = 1.0) -> [String: Any]? {
        subscription?.next(timeout: timeout)
    }

    private func payload(of event: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(event["payload"] as? [String: Any])
    }

    func testSettingAPanelCustomTitlePublishesSurfaceRenamed() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Build logs"))

        let event = try XCTUnwrap(nextEvent(), "a user rename must reach the events stream")
        XCTAssertEqual(event["name"] as? String, "surface.renamed")
        XCTAssertEqual(event["category"] as? String, "surface")
        XCTAssertEqual(event["workspace_id"] as? String, workspace.id.uuidString)
        XCTAssertEqual(event["surface_id"] as? String, panelId.uuidString)
        let body = try payload(of: event)
        XCTAssertEqual(body["surface_id"] as? String, panelId.uuidString)
        XCTAssertTrue(body["previous_title"] is NSNull, "a first rename has no previous custom title")
        XCTAssertEqual(body["title"] as? String, "Build logs")
        XCTAssertEqual(body["title_source"] as? String, "user")
        XCTAssertTrue(body["origin"] is NSNull, "a caller that names no entry point reports a null origin")
    }

    func testEntryPointsReportTheirOrigin() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Typed in", renameOrigin: "ui"))
        let typed = try payload(of: try XCTUnwrap(nextEvent()))
        XCTAssertEqual(typed["origin"] as? String, "ui")
        XCTAssertEqual(typed["title_source"] as? String, "user")

        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "cmux rename-tab", renameOrigin: "socket"))
        let sent = try payload(of: try XCTUnwrap(nextEvent()))
        XCTAssertEqual(sent["origin"] as? String, "socket")
        XCTAssertEqual(sent["title_source"] as? String, "user", "the socket rename is still a user-owned title")
    }

    /// The tab context menu's Clear Name is a UI entry point like typing a name.
    func testClearingANameFromTheTabContextMenuReportsTheUIOrigin() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Named", renameOrigin: "ui"))
        _ = try XCTUnwrap(nextEvent())

        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panelId))
        let tab = try XCTUnwrap(workspace.bonsplitController.tab(tabId))
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: panelId))
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .clearName,
            for: tab,
            inPane: paneId
        )

        let cleared = try payload(of: try XCTUnwrap(nextEvent(), "clearing a name must reach the events stream"))
        XCTAssertEqual(cleared["previous_title"] as? String, "Named")
        XCTAssertTrue(cleared["title"] is NSNull)
        XCTAssertEqual(cleared["origin"] as? String, "ui")
    }

    func testRepeatingTheSameTitlePublishesNothing() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Build logs"))
        XCTAssertNotNil(nextEvent())

        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Build logs"))
        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "  Build logs  "))

        XCTAssertNil(nextEvent(timeout: 0.3), "an unchanged title is not a rename")
    }

    func testReplacingAndClearingReportBothTitles() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Build logs"))
        XCTAssertNotNil(nextEvent())

        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Deploy"))
        let replaced = try payload(of: try XCTUnwrap(nextEvent()))
        XCTAssertEqual(replaced["previous_title"] as? String, "Build logs")
        XCTAssertEqual(replaced["title"] as? String, "Deploy")

        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: nil))
        let cleared = try payload(of: try XCTUnwrap(nextEvent()))
        XCTAssertEqual(cleared["previous_title"] as? String, "Deploy")
        XCTAssertTrue(cleared["title"] is NSNull, "clearing reports a null title")
        XCTAssertEqual(cleared["title_source"] as? String, "user")
    }

    func testAgentAutoNamingReportsItsSource() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Fix the flaky test", source: .auto))

        let body = try payload(of: try XCTUnwrap(nextEvent()))
        XCTAssertEqual(body["title"] as? String, "Fix the flaky test")
        XCTAssertEqual(body["title_source"] as? String, "auto")
    }

    func testCreationTimeNamesOptOut() throws {
        // Session restore and layout creation name a tab as part of creating
        // it; that is not a rename.
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Restored name", publishesRenameEvent: false))
        XCTAssertEqual(workspace.panelCustomTitles[panelId], "Restored name")

        XCTAssertNil(nextEvent(timeout: 0.3))
    }

    func testRejectedRenamePublishesNothing() throws {
        let workspace = Workspace()
        defer { for panel in workspace.panels.values { panel.close() } }
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(workspace.setPanelCustomTitle(panelId: panelId, title: "Mine"))
        XCTAssertNotNil(nextEvent())

        // Auto-naming may not overwrite a user's title, so nothing changes.
        XCTAssertFalse(workspace.setPanelCustomTitle(panelId: panelId, title: "Agent idea", source: .auto))
        XCTAssertFalse(workspace.setPanelCustomTitle(panelId: UUID(), title: "Nobody"))

        XCTAssertNil(nextEvent(timeout: 0.3))
    }
}
