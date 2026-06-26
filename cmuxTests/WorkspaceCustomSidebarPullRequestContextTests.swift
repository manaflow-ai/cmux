import XCTest
import CmuxWorkspaces
import CmuxSwiftRender

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceCustomSidebarPullRequestContextTests: XCTestCase {
    @MainActor
    func testCustomSidebarSurfacePersistsAndRestoresAsPane() throws {
        let sidebarName = "__cmux_restore_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(sidebarName).swift")
            try #"Text("Restored")"#.write(to: fileURL, atomically: true, encoding: .utf8)
            CmuxEventBus.shared.resetForTesting()
            defer { CmuxEventBus.shared.resetForTesting() }

            let workspace = Workspace()
            let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
            CmuxEventBus.shared.resetForTesting()
            let panel = try XCTUnwrap(
                workspace.newCustomSidebarSurface(inPane: paneId, name: sidebarName, focus: true)
            )
            let surfaceEvent = try XCTUnwrap(
                CmuxEventBus.shared.retainedSnapshot().first { $0["name"] as? String == "surface.created" }
            )
            let surfacePayload = try XCTUnwrap(surfaceEvent["payload"] as? [String: Any])
            XCTAssertEqual(surfacePayload["kind"] as? String, "custom_sidebar")

            let snapshot = workspace.sessionSnapshot(includeScrollback: false)
            let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panel.id })
            XCTAssertEqual(panelSnapshot.type, .customSidebar)
            XCTAssertEqual(panelSnapshot.customSidebar?.name, sidebarName)

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)

            let restoredPanel = try XCTUnwrap(
                restored.panels.values.compactMap { $0 as? CustomSidebarPanel }.first { $0.name == sidebarName }
            )
            XCTAssertEqual(restoredPanel.panelType, .customSidebar)
            XCTAssertEqual(
                restored.surfaceIdFromPanelId(restoredPanel.id).flatMap { restored.bonsplitController.tab($0)?.kind },
                SurfaceKind.customSidebar.rawValue
            )
        }
    }

    @MainActor
    func testSplitCustomSidebarPublishesNewPaneLifecycleEvents() throws {
        let sidebarName = "__cmux_split_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(sidebarName).swift")
            try #"Text("Split")"#.write(to: fileURL, atomically: true, encoding: .utf8)
            CmuxEventBus.shared.resetForTesting()
            defer { CmuxEventBus.shared.resetForTesting() }

            let workspace = Workspace()
            let sourcePaneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
            CmuxEventBus.shared.resetForTesting()

            let panel = try XCTUnwrap(
                workspace.splitPaneWithCustomSidebar(
                    targetPane: sourcePaneId,
                    orientation: .horizontal,
                    insertFirst: false,
                    name: sidebarName
                )
            )
            let customPaneId = try XCTUnwrap(workspace.paneId(forPanelId: panel.id))

            XCTAssertNotEqual(customPaneId.id, sourcePaneId.id)
            let events = CmuxEventBus.shared.retainedSnapshot()
            let paneEvent = try XCTUnwrap(events.first { $0["name"] as? String == "pane.created" })
            XCTAssertEqual(paneEvent["pane_id"] as? String, customPaneId.id.uuidString)
            let panePayload = try XCTUnwrap(paneEvent["payload"] as? [String: Any])
            XCTAssertEqual(panePayload["pane_id"] as? String, customPaneId.id.uuidString)
            XCTAssertEqual(panePayload["source_pane_id"] as? String, sourcePaneId.id.uuidString)
            XCTAssertEqual(panePayload["surface_id"] as? String, panel.id.uuidString)

            let surfaceEvent = try XCTUnwrap(events.first { $0["name"] as? String == "surface.created" })
            XCTAssertEqual(surfaceEvent["surface_id"] as? String, panel.id.uuidString)
            XCTAssertEqual(surfaceEvent["pane_id"] as? String, customPaneId.id.uuidString)
            let surfacePayload = try XCTUnwrap(surfaceEvent["payload"] as? [String: Any])
            XCTAssertEqual(surfacePayload["pane_id"] as? String, customPaneId.id.uuidString)
            XCTAssertEqual(surfacePayload["kind"] as? String, "custom_sidebar")
        }
    }

    func testV2CustomSidebarOpenReturnsErrorWhenValidationFails() throws {
        let missingName = "__cmux_missing_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { _ in

            switch TerminalController.shared.v2CustomSidebarOpen(params: ["name": missingName]) {
            case .err(let code, _, let data):
                XCTAssertEqual(code, "validation_failed")
                let payload = data as? [String: Any]
                XCTAssertEqual(payload?["error_count"] as? Int, 1)
            case .ok(let payload):
                XCTFail("Expected validation error, got \(payload)")
            }
        }
    }

    @MainActor
    func testV2CustomSidebarOpenRejectsMalformedWorkspaceTarget() throws {
        let sidebarName = "__cmux_target_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(sidebarName).swift")
            try #"Text("Target")"#.write(to: fileURL, atomically: true, encoding: .utf8)

            switch TerminalController.shared.v2CustomSidebarOpen(
                params: ["name": sidebarName, "workspace_id": "not-a-workspace"]
            ) {
            case .err(let code, let message, _):
                XCTAssertEqual(code, "invalid_params")
                XCTAssertEqual(message, "Missing or invalid workspace_id")
            case .ok(let payload):
                XCTFail("Expected invalid_params, got \(payload)")
            }
        }
    }

    @MainActor
    func testV2CustomSidebarOpenFallsBackWhenFocusedPanelCannotSplit() throws {
        let sidebarName = "__cmux_fallback_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(sidebarName).swift")
            try #"Text("Fallback")"#.write(to: fileURL, atomically: true, encoding: .utf8)

            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            defer { AppDelegate.shared = previousAppDelegate }

            let tabManager = TabManager()
            let workspace = tabManager.addWorkspace(select: true, eagerLoadTerminal: false)
            let windowId = UUID()
            appDelegate.registerMainWindowContextForTesting(
                windowId: windowId,
                tabManager: tabManager,
                fileExplorerState: FileExplorerState()
            )
            defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

            let staleFocusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
            workspace.panels.removeValue(forKey: staleFocusedPanelId)

            switch TerminalController.shared.v2CustomSidebarOpen(
                params: ["name": sidebarName, "workspace_id": workspace.id.uuidString, "focus": true]
            ) {
            case .ok(let payload):
                let dictionary = try XCTUnwrap(payload as? [String: Any])
                XCTAssertEqual(dictionary["opened_name"] as? String, sidebarName)
                XCTAssertEqual(dictionary["type"] as? String, PanelType.customSidebar.rawValue)
            case .err(let code, let message, _):
                XCTFail("Expected fallback open to succeed, got \(code): \(message)")
            }

            XCTAssertNotNil(
                workspace.panels.values.compactMap { $0 as? CustomSidebarPanel }.first { $0.name == sidebarName }
            )
        }
    }

    @MainActor
    func testValuesIncludePanelPullRequestWhenFocusedPanelMirrorIsNil() throws {
        let workspace = Workspace(
            title: "Tests",
            workingDirectory: FileManager.default.currentDirectoryPath,
            portOrdinal: 0
        )
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 5314,
            label: "PR",
            url: URL(string: "https://github.com/manaflow-ai/cmux/pull/5314")!,
            status: .open
        )
        // The focused-panel `pullRequest` mirror only refreshes while its panel
        // is focused, so live sessions routinely hold panel pull requests with a
        // nil mirror. The interpreter context must project from the per-panel
        // state, not the mirror.
        workspace.pullRequest = nil

        let values = workspace.customSidebarPullRequestValues()
        XCTAssertEqual(values.count, 1)
        guard case .object(let fields)? = values.first else {
            XCTFail("Expected object pull-request value, got \(String(describing: values.first))")
            return
        }
        XCTAssertEqual(fields["number"], .int(5314))
        XCTAssertEqual(fields["status"], .string("open"))
        XCTAssertEqual(fields["ciStatus"], .string("neutral"))
        XCTAssertEqual(fields["url"], .string("https://github.com/manaflow-ai/cmux/pull/5314"))
        XCTAssertEqual(fields["stale"], .bool(false))
    }

    @MainActor
    func testValuesEmptyWhenWorkspaceHasNoPullRequests() {
        let workspace = Workspace(
            title: "Tests",
            workingDirectory: FileManager.default.currentDirectoryPath,
            portOrdinal: 0
        )

        XCTAssertEqual(workspace.customSidebarPullRequestValues(), [])
    }

    private func withTemporaryCustomSidebarsDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebars-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(directory) {
            try body(directory)
        }
    }
}
