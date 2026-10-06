import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct DockMaximizeStateTests {
    private func makeState() -> (FileExplorerState, UserDefaults) {
        let suite = "cmux.dockMaximize.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (FileExplorerState(defaults: defaults), defaults)
    }

    @Test func maximizeShowsTheDock() {
        let (state, _) = makeState()
        state.setVisible(false)
        state.mode = .files

        state.setDockMaximized(true)

        #expect(state.isVisible)
        #expect(state.mode == .dock)
        #expect(state.isDockMaximized)
    }

    @Test func restoreKeepsAVisibleDockVisible() {
        let (state, _) = makeState()
        state.setVisible(true)
        state.mode = .dock
        state.setDockMaximized(true)

        state.setDockMaximized(false)

        #expect(!state.isDockMaximized)
        #expect(state.isVisible)
        #expect(state.mode == .dock)
    }

    @Test func restoreReturnsToTheSidebarStateBeforeMaximize() {
        let (state, _) = makeState()
        state.setVisible(false)
        state.mode = .files
        state.setDockMaximized(true)

        state.setDockMaximized(false)

        #expect(!state.isDockMaximized)
        #expect(!state.isVisible)
        #expect(state.mode == .files)
        #expect(state.dockMaximizeRestoreTarget == nil)
    }

    @Test func restoreReturnsToThePreviousVisibleMode() {
        let (state, _) = makeState()
        state.setVisible(true)
        state.mode = .files
        state.setDockMaximized(true)

        state.setDockMaximized(false)

        #expect(state.isVisible)
        #expect(state.mode == .files)
    }

    @Test func hidingTheRightSidebarExitsMaximize() {
        let (state, _) = makeState()
        state.setDockMaximized(true)

        state.setVisible(false)

        #expect(!state.isDockMaximized)
        state.setVisible(true)
        #expect(!state.isDockMaximized)
    }

    @Test func autoCollapseExitsMaximize() {
        let (state, _) = makeState()
        state.setDockMaximized(true)

        state.isAutoCollapsed = true
        state.isVisible = false

        #expect(!state.isDockMaximized)
    }

    @Test func switchingAwayFromDockExitsMaximize() {
        let (state, _) = makeState()
        state.setDockMaximized(true)

        state.mode = .files

        #expect(!state.isDockMaximized)
        #expect(state.isVisible)
    }

    @Test func maximizeIsNotPersistedInDefaults() {
        let (state, defaults) = makeState()
        state.setDockMaximized(true)

        let reloaded = FileExplorerState(defaults: defaults)

        #expect(!reloaded.isDockMaximized)
    }

    @Test func toggleRequestFlipsCurrentState() {
        #expect(DockMaximizeRequest.toggle.resolvedMaximized(currentlyMaximized: false))
        #expect(!DockMaximizeRequest.toggle.resolvedMaximized(currentlyMaximized: true))
        #expect(DockMaximizeRequest.maximize.resolvedMaximized(currentlyMaximized: true))
        #expect(!DockMaximizeRequest.restore.resolvedMaximized(currentlyMaximized: false))
    }
}

@Suite struct DockMaximizeWidthTests {
    @Test func normalPanelKeepsItsWidth() {
        let width = ContentView.rightSidebarPanelWidth(
            normalWidth: 320,
            isDockMaximized: false,
            coverableWidth: 1200
        )
        #expect(width == 320)
    }

    @Test func maximizedPanelFillsTheCoverableWidth() {
        let width = ContentView.rightSidebarPanelWidth(
            normalWidth: 320,
            isDockMaximized: true,
            coverableWidth: 1200
        )
        #expect(width == 1200)
    }

    @Test func mainAreaKeepsTheWidthItHadBeforeMaximize() {
        let fromHidden = DockMaximizeRestoreTarget(isVisible: false, mode: .files)
        let fromVisible = DockMaximizeRestoreTarget(isVisible: true, mode: .dock)
        #expect(ContentView.reservedRightSidebarWidth(normalWidth: 320, isDockMaximized: true, restoreTarget: fromHidden) == 0)
        #expect(ContentView.reservedRightSidebarWidth(normalWidth: 320, isDockMaximized: true, restoreTarget: fromVisible) == 320)
        #expect(ContentView.reservedRightSidebarWidth(normalWidth: 320, isDockMaximized: true, restoreTarget: nil) == 320)
        #expect(ContentView.reservedRightSidebarWidth(normalWidth: 320, isDockMaximized: false, restoreTarget: fromHidden) == 320)
    }

    @Test func maximizedPanelNeverShrinksBelowNormalWidth() {
        #expect(ContentView.rightSidebarPanelWidth(normalWidth: 320, isDockMaximized: true, coverableWidth: 100) == 320)
        #expect(ContentView.rightSidebarPanelWidth(normalWidth: 320, isDockMaximized: true, coverableWidth: .infinity) == 320)
    }
}

@Suite struct DockMaximizeSessionSnapshotTests {
    @Test func olderSnapshotsDecodeAsNotMaximized() throws {
        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        object.removeValue(forKey: "rightSidebarDockMaximized")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SessionWindowSnapshot.self, from: legacyData)

        #expect(decoded.rightSidebarDockMaximized == nil)
    }

    @Test func maximizedFlagRoundTrips() throws {
        var snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        snapshot.rightSidebarDockMaximized = true

        let decoded = try JSONDecoder().decode(
            SessionWindowSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(decoded.rightSidebarDockMaximized == true)
    }
}

extension TerminalControllerSocketSecurityTests {
    @Test func v1ParserProducesDockMaximizeCommands() throws {
#if DEBUG
        let windowId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let cases: [(String, RightSidebarRemoteRequest)] = [
            ("right_sidebar maximize", RightSidebarRemoteRequest(command: .maximize, target: RightSidebarRemoteTarget())),
            ("right_sidebar restore", RightSidebarRemoteRequest(command: .restore, target: RightSidebarRemoteTarget())),
            (
                "right_sidebar toggle-maximize --window=\(windowId.uuidString)",
                RightSidebarRemoteRequest(command: .toggleMaximize, target: RightSidebarRemoteTarget(windowId: windowId, workspaceId: nil))
            ),
        ]
        for (line, expected) in cases {
            let result = TerminalController.shared.parseRightSidebarRemoteRequestForTesting(line)
            #expect(try result.get() == expected, Comment(rawValue: line))
        }

        for line in ["right_sidebar maximize --no-focus", "right_sidebar restore extra"] {
            if case .success(let request) = TerminalController.shared.parseRightSidebarRemoteRequestForTesting(line) {
                Issue.record("Expected parser failure for \(line), got \(request)")
            }
        }

        for line in ["right_sidebar maximize", "right_sidebar restore", "right_sidebar toggle-maximize"] {
            #expect(
                TerminalController.shared.rightSidebarCommandAllowsInAppFocusMutationsForTesting(line),
                Comment(rawValue: line)
            )
        }
#endif
    }

    @Test func v1DockMaximizeCommandsDriveWindowState() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let tabManager = TabManager()
        let fileExplorerState = FileExplorerState()
        fileExplorerState.setVisible(false)
        fileExplorerState.mode = .files

        appDelegate.fileExplorerState = fileExplorerState
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowId,
            tabManager: tabManager,
            fileExplorerState: fileExplorerState
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        func modePayload() throws -> [String: Any] {
            let response = TerminalController.shared.handleSocketLine("right_sidebar mode")
            let data = try #require(response.data(using: .utf8))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        #expect(try modePayload()["maximized"] as? Bool == false)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar maximize") == "OK")
        #expect(fileExplorerState.isDockMaximized)
        #expect(fileExplorerState.isVisible)
        #expect(fileExplorerState.mode == .dock)
        let maximized = try modePayload()
        #expect(maximized["maximized"] as? Bool == true)
        #expect(maximized["mode"] as? String == "dock")

        #expect(TerminalController.shared.handleSocketLine("right_sidebar restore") == "OK")
        #expect(!fileExplorerState.isDockMaximized)
        #expect(!fileExplorerState.isVisible)
        #expect(fileExplorerState.mode == .files)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar toggle-maximize") == "OK")
        #expect(fileExplorerState.isDockMaximized)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar hide") == "OK")
        #expect(!fileExplorerState.isDockMaximized)
        #expect(try modePayload()["maximized"] as? Bool == false)
    }
}
