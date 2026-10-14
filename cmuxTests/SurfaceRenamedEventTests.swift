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
