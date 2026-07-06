import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CrashDiagnosticSessionPolicyTests {
    @Test
    func terminalDefaultFileOpenIgnoresGhosttyCrashReportsInCmuxCrashDirectory() {
        let crashReport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash/cmux.ghosttycrash", isDirectory: false)

        #expect(
            TerminalDefaultFileOpenRequest(
                fileURL: crashReport,
                contentType: .unixExecutable,
                isExecutable: true
            ) == nil
        )
    }

    @Test
    func terminalDefaultFileOpenIgnoresSymlinkedGhosttyCrashReportsInCmuxCrashDirectory() throws {
        let crashReport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash/cmux.ghosttycrash", isDirectory: false)
        let symlink = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-symlinked-crash-\(UUID().uuidString).ghosttycrash", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: crashReport)
        defer {
            try? FileManager.default.removeItem(at: symlink)
        }

        #expect(
            TerminalDefaultFileOpenRequest(
                fileURL: symlink,
                contentType: .unixExecutable,
                isExecutable: true
            ) == nil
        )
    }

    @MainActor
    @Test
    func appDelegateSessionSnapshotDropsCrashDiagnosticWindow() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let projectDirectory = "/tmp/cmux-project"
        let projectManager = TabManager(
            initialWorkingDirectory: projectDirectory,
            autoWelcomeIfNeeded: false
        )
        let projectWindowId = app.registerMainWindowContextForTesting(tabManager: projectManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: projectWindowId)
        }

        let crashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
            .path
        let crashManager = TabManager(
            initialWorkingDirectory: crashDirectory,
            autoWelcomeIfNeeded: false
        )
        let crashWindowId = app.registerMainWindowContextForTesting(tabManager: crashManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: crashWindowId)
        }

        let snapshot = try #require(app.debugBuildSessionSnapshotForTesting(includeScrollback: false))
        let restoredDirectories = snapshot.windows.flatMap { window in
            window.tabManager.workspaces.map(\.currentDirectory)
        }

        #expect(snapshot.windows.count == 1)
        #expect(restoredDirectories == [projectDirectory])
    }

    @MainActor
    @Test
    func closedWindowHistorySkipsCrashDiagnosticWindow() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = previousAppDelegate
        }

        let crashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
            .path
        let crashManager = TabManager(
            initialWorkingDirectory: crashDirectory,
            autoWelcomeIfNeeded: false
        )
        let crashWindowId = app.registerMainWindowContextForTesting(tabManager: crashManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: crashWindowId)
        }

        app.recordClosedWindowHistoryForTesting(windowId: crashWindowId)

        #expect(!ClosedItemHistoryStore.shared.canReopen)
    }

    @Test
    func sessionSnapshotDropsEmptyCrashDiagnosticWorkspace() {
        let projectDirectory = "/tmp/cmux-project"
        let crashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
            .path
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(
                        selectedWorkspaceIndex: 0,
                        workspaces: [
                            emptyWorkspaceSnapshot(currentDirectory: crashDirectory),
                            emptyWorkspaceSnapshot(currentDirectory: projectDirectory),
                        ]
                    ),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )

        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot)

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.currentDirectory) == [projectDirectory])
        #expect(pruned.snapshot?.windows.first?.tabManager.selectedWorkspaceIndex == 0)
    }

    @Test
    func sessionSnapshotKeepsCrashWorkspaceWithPersistedScrollback() {
        let projectDirectory = "/tmp/cmux-project"
        let crashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
            .path
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(
                        selectedWorkspaceIndex: 0,
                        workspaces: [
                            terminalWorkspaceSnapshot(
                                currentDirectory: crashDirectory,
                                terminal: SessionTerminalPanelSnapshot(
                                    workingDirectory: crashDirectory,
                                    scrollback: "ls\ncmux.ghosttycrash\n"
                                )
                            ),
                            emptyWorkspaceSnapshot(currentDirectory: projectDirectory),
                        ]
                    ),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )

        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot)

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.currentDirectory) == [
            crashDirectory,
            projectDirectory,
        ])
    }

    @Test
    func sessionSnapshotKeepsCrashWorkspaceWithTextBoxDraft() {
        let projectDirectory = "/tmp/cmux-project"
        let crashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
            .path
        let draft = SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.text("inspect crash report")]
        )
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(
                        selectedWorkspaceIndex: 0,
                        workspaces: [
                            terminalWorkspaceSnapshot(
                                currentDirectory: crashDirectory,
                                terminal: SessionTerminalPanelSnapshot(
                                    workingDirectory: crashDirectory,
                                    textBoxDraft: draft
                                )
                            ),
                            emptyWorkspaceSnapshot(currentDirectory: projectDirectory),
                        ]
                    ),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )

        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot)

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.currentDirectory) == [
            crashDirectory,
            projectDirectory,
        ])
    }

    @Test
    func sessionSnapshotPruningDoesNotResolveSymlinkedCrashDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-storage-symlink-\(UUID().uuidString)", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let crashDirectory = homeDirectory
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
        let symlink = root.appendingPathComponent("crash-link", isDirectory: true)
        try FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: crashDirectory)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        #expect(!SessionPersistencePolicy.isCmuxCrashStoragePath(
            symlink.path,
            homeDirectory: homeDirectory,
            environment: [:]
        ))

        let window = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [emptyWorkspaceSnapshot(currentDirectory: symlink.path)]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )

        #expect(!SessionPersistencePolicy.isCmuxCrashDiagnosticWindow(
            window,
            homeDirectory: homeDirectory,
            environment: [:]
        ))

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [window]
        )

        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(
            from: snapshot,
            homeDirectory: homeDirectory,
            environment: [:]
        )
        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.first?.currentDirectory == symlink.path)
    }

    @Test
    func pendingCrashChoosesLatestReportAcrossCrashDirectories() throws {
        let defaultsSuiteName = "CrashDiagnosticSessionPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }

        let defaultCrashDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-crash-breadcrumb-default-\(UUID().uuidString)", isDirectory: true)
        let xdgCrashDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-crash-breadcrumb-xdg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultCrashDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xdgCrashDirectoryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: defaultCrashDirectoryURL)
            try? FileManager.default.removeItem(at: xdgCrashDirectoryURL)
        }

        let cleanExit = Date(timeIntervalSince1970: 100)
        let defaultCrashDate = Date(timeIntervalSince1970: 200)
        let xdgCrashDate = Date(timeIntervalSince1970: 300)
        defaults.set(cleanExit, forKey: GhosttyCrashBreadcrumb.lastCleanExitDefaultsKey)
        _ = try writeCrashFile(
            named: "default.ghosttycrash",
            modifiedAt: defaultCrashDate,
            in: defaultCrashDirectoryURL
        )
        let xdgCrashURL = try writeCrashFile(
            named: "xdg.ghosttycrash",
            modifiedAt: xdgCrashDate,
            in: xdgCrashDirectoryURL
        )

        let pending = GhosttyCrashBreadcrumb.pendingCrash(
            in: [defaultCrashDirectoryURL, xdgCrashDirectoryURL],
            defaults: defaults
        )

        #expect(pending?.fileURL.resolvingSymlinksInPath() == xdgCrashURL.resolvingSymlinksInPath())
        #expect(pending?.modifiedAt == xdgCrashDate)
    }

    @Test
    func crashOnlyPrimarySnapshotRemovalMarkerPersistsUntilCleared() throws {
        let defaultsSuiteName = "CrashDiagnosticSessionPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }

        #expect(!AppDelegate.hasCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults))

        AppDelegate.markCrashOnlyPrimarySnapshotRemoval(defaults: defaults)

        #expect(AppDelegate.hasCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults))
        #expect(AppDelegate.hasCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults))

        AppDelegate.clearCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)

        #expect(!AppDelegate.hasCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults))
    }

    private func emptyWorkspaceSnapshot(currentDirectory: String) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: currentDirectory,
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
    }

    private func terminalWorkspaceSnapshot(
        currentDirectory: String,
        terminal: SessionTerminalPanelSnapshot = SessionTerminalPanelSnapshot()
    ) -> SessionWorkspaceSnapshot {
        let panelId = UUID()
        return SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: currentDirectory,
            focusedPanelId: panelId,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)),
            panels: [
                terminalPanelSnapshot(
                    id: panelId,
                    directory: currentDirectory,
                    terminal: terminal
                ),
            ],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
    }

    private func terminalPanelSnapshot(
        id: UUID,
        directory: String,
        terminal: SessionTerminalPanelSnapshot
    ) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "Terminal",
            customTitle: nil,
            directory: directory,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: terminal,
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }

    private func writeCrashFile(
        named name: String,
        modifiedAt: Date,
        in directoryURL: URL
    ) throws -> URL {
        let url = directoryURL.appendingPathComponent(name)
        try Data("MDMP".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }
}
