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

    @Test func unsafeThemeNamesAreRejectedBeforeConfigGeneration() {
        #expect(WorkspaceGhosttyThemeSelection.single("Injected\nfont-size = 200").configContents() == nil)
        #expect(WorkspaceGhosttyThemeSelection(light: "Safe", dark: "Bad\u{0}Theme").configContents() == nil)
        #expect(WorkspaceGhosttyThemeSelection.fromRawValue("theme\nfont-size = 200") == nil)
    }

    @Test func concreteConfigContentsResolvesConditionalThemeForColorScheme() {
        let selection = WorkspaceGhosttyThemeSelection(
            light: "Catppuccin Latte",
            dark: "Catppuccin Mocha"
        )

        #expect(selection.configContents() == "theme = light:Catppuccin Latte,dark:Catppuccin Mocha")
        #expect(selection.configContents(preferredColorScheme: .light) == "theme = Catppuccin Latte")
        #expect(selection.configContents(preferredColorScheme: .dark) == "theme = Catppuccin Mocha")
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

    @Test func catalogPrefersBundledThemesOverInheritedResourcesDir() throws {
        let bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bundle-themes-\(UUID().uuidString)", isDirectory: true)
        let envRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-env-themes-\(UUID().uuidString)", isDirectory: true)
        let bundleThemes = bundleRoot
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
        let envThemes = envRoot.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleThemes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: envThemes, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: bundleRoot)
            try? FileManager.default.removeItem(at: envRoot)
        }

        try "background = #111111\n".write(
            to: bundleThemes.appendingPathComponent("Bundled Case Theme", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "background = #222222\n".write(
            to: envThemes.appendingPathComponent("bundled case theme", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "background = #333333\n".write(
            to: envThemes.appendingPathComponent("Env Only Theme", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let names = WorkspaceGhosttyThemeCatalog.availableThemeNames(
            environment: ["GHOSTTY_RESOURCES_DIR": envRoot.path],
            bundleResourceURL: bundleRoot
        )

        #expect(names == ["Bundled Case Theme"])
    }

    @Test func catalogIncludesSymlinkedThemeFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-symlink-theme-\(UUID().uuidString)", isDirectory: true)
        let themes = root
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("Target Theme", isDirectory: false)
        try "background = #123456\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: themes.appendingPathComponent("Linked Theme", isDirectory: false),
            withDestinationURL: target
        )

        let names = WorkspaceGhosttyThemeCatalog.availableThemeNames(
            environment: ["XDG_DATA_DIRS": root.path],
            bundleResourceURL: nil
        )

        #expect(names.contains("Linked Theme"))
    }

    @Test func validationAllowsExistingAbsoluteThemeFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-absolute-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let themeFile = root.appendingPathComponent("Absolute Theme", isDirectory: false)
        try "background = #abcdef\n".write(to: themeFile, atomically: true, encoding: .utf8)

        #expect(
            WorkspaceGhosttyThemeCatalog.validatedThemeName(
                themeFile.path,
                availableThemes: ["Bundled Theme"]
            ) == themeFile.standardizedFileURL.path
        )
        #expect(
            WorkspaceGhosttyThemeCatalog.validatedThemeName(
                root.path,
                availableThemes: ["Bundled Theme"]
            ) == nil
        )
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
