import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace Ghostty Theme")
struct WorkspaceGhosttyThemeTests {
    @Test func partialOverrideDoesNotEmitGhosttyConfig() {
        #expect(WorkspaceGhosttyThemeSelection(light: "Catppuccin Latte", dark: nil).configContents() == nil)
        #expect(WorkspaceGhosttyThemeSelection(light: nil, dark: "Catppuccin Mocha").configContents() == nil)
    }

    @Test func catalogIncludesXDGDataDirs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-theme-catalog-\(UUID().uuidString)", isDirectory: true)
        let themes = root
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let themeFile = themes.appendingPathComponent("XDG Test Theme", isDirectory: false)
        try "background = #112233\n".write(to: themeFile, atomically: true, encoding: .utf8)

        let names = WorkspaceGhosttyThemeCatalog.availableThemeNames(
            environment: ["XDG_DATA_DIRS": root.path],
            bundleResourceURL: nil
        )

        #expect(names.contains("XDG Test Theme"))
    }

    @Test func sessionRoundTripPreservesWorkspaceThemeSelection() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].ghosttyThemeSelection = WorkspaceGhosttyThemeSelection(
            light: "Catppuccin Latte",
            dark: "Catppuccin Mocha"
        )

        #expect(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let loaded = try #require(SessionPersistenceStore.load(fileURL: snapshotURL))

        #expect(
            loaded.windows.first?.tabManager.workspaces.first?.ghosttyThemeSelection
                == WorkspaceGhosttyThemeSelection(light: "Catppuccin Latte", dark: "Catppuccin Mocha")
        )
    }

    @Test func nilWorkspaceThemeSelectionIsOmittedForLegacyCompatibility() throws {
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].ghosttyThemeSelection = nil

        let data = try JSONEncoder().encode(snapshot)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"ghosttyThemeSelection\""))

        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        #expect(decoded.windows.first?.tabManager.workspaces.first?.ghosttyThemeSelection == nil)
    }

    @MainActor
    @Test func sessionAutosaveFingerprintChangesWhenWorkspaceThemeChanges() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)

        let baselineFingerprint = manager.sessionAutosaveFingerprint()
        workspace.setGhosttyThemeSelection(
            WorkspaceGhosttyThemeSelection(light: "Catppuccin Latte", dark: "Catppuccin Mocha"),
            reload: false
        )
        let firstThemeFingerprint = manager.sessionAutosaveFingerprint()

        workspace.setGhosttyThemeSelection(
            WorkspaceGhosttyThemeSelection(light: "Catppuccin Latte", dark: "Solarized Dark"),
            reload: false
        )
        let secondThemeFingerprint = manager.sessionAutosaveFingerprint()

        #expect(firstThemeFingerprint != baselineFingerprint)
        #expect(secondThemeFingerprint != firstThemeFingerprint)
    }

    private func makeSnapshot(version: Int) -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Restored",
            customColor: nil,
            isPinned: true,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )

        let tabManager = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [workspace]
        )

        let window = SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
            display: SessionDisplaySnapshot(
                displayID: 42,
                frame: SessionRectSnapshot(x: 0, y: 0, width: 1920, height: 1200),
                visibleFrame: SessionRectSnapshot(x: 0, y: 25, width: 1920, height: 1175)
            ),
            tabManager: tabManager,
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )

        return AppSessionSnapshot(
            version: version,
            createdAt: Date().timeIntervalSince1970,
            windows: [window]
        )
    }
}
