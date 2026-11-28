import AppKit
import CmuxWorkspaces
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
        // The fixture owns its crash directory instead of borrowing the real one.
        // resolvingSymlinksInPath() only resolves a symlink whose target exists, so the report has
        // to be created, and planting one in ~/.local/state/cmux/crash would look like a pending
        // crash on the next launch. XDG_STATE_HOME is the product's own second crash location.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-symlinked-crash-\(UUID().uuidString)", isDirectory: true)
        let stateHome = root.appendingPathComponent("state", isDirectory: true)
        let crashReport = stateHome
            .appendingPathComponent("cmux/crash/cmux.ghosttycrash", isDirectory: false)
        try FileManager.default.createDirectory(
            at: crashReport.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("MDMP".utf8).write(to: crashReport)
        let symlink = root.appendingPathComponent("crash-link.ghosttycrash", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: crashReport)
        // Read the live value with getenv: ProcessInfo caches the environment at first
        // access, so if an earlier test setenv'd this variable at runtime, restoring the
        // ProcessInfo snapshot in the defer below would clobber that test's state.
        let previousStateHome = getenv("XDG_STATE_HOME").map { String(cString: $0) }
        setenv("XDG_STATE_HOME", stateHome.path(percentEncoded: false), 1)
        defer {
            if let previousStateHome {
                setenv("XDG_STATE_HOME", previousStateHome, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
            try? FileManager.default.removeItem(at: root)
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
    func sessionSnapshotDropsPhantomWindowsButKeepsDockOnlyWindows() {
        let projectDirectory = "/tmp/cmux-project"
        func window(workspaces: [SessionWorkspaceSnapshot], dock: SessionSplitContainerSnapshot? = nil) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: workspaces),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil),
                dock: dock
            )
        }
        let dock = SessionSplitContainerSnapshot(
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: []
        )
        let mixed = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                window(workspaces: []),
                window(workspaces: [emptyWorkspaceSnapshot(currentDirectory: projectDirectory)]),
                window(workspaces: [], dock: dock),
            ]
        )

        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: mixed)

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 2)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.currentDirectory) == [projectDirectory])
        #expect(pruned.snapshot?.windows.last?.dock != nil)

        // An all-phantom session (#6646: three 0-tab windows) is not restorable.
        let allPhantom = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [window(workspaces: []), window(workspaces: []), window(workspaces: [])]
        )
        let prunedAllPhantom = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: allPhantom)
        // Not crash-diagnostic data: callers must not treat it as such.
        #expect(!prunedAllPhantom.removedAny)
        #expect(prunedAllPhantom.snapshot == nil)
    }

    @Test
    func sessionSnapshotDropsAnExactDuplicateWindowManifest() {
        let workspaceID = UUID()
        var workspace = terminalWorkspaceSnapshot(currentDirectory: "/tmp/cmux-project")
        workspace.workspaceId = workspaceID
        let window = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspace]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [window, window]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.first?.workspaceId == workspaceID)
    }

    @Test
    func sessionSnapshotKeepsTheRicherCopyWhenCrashWindowsShareAgentCheckpoints() {
        let checkpointID = "01a149a7-fbec-7240-9c88-ed6faec559ca"
        let projectDirectory = "/Volumes/Workshop/Code/pulp"
        let panelID = UUID()
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: checkpointID,
            workingDirectory: projectDirectory
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "codex resume \(checkpointID)",
            cwd: projectDirectory,
            checkpointId: checkpointID,
            source: "agent-hook",
            autoResume: true
        )
        let richTerminal = SessionTerminalPanelSnapshot(
            workingDirectory: projectDirectory,
            agent: agent,
            resumeBinding: binding,
            wasAgentRunning: true
        )
        let degradedTerminal = SessionTerminalPanelSnapshot(
            workingDirectory: "/Users/danielraffel",
            agent: agent,
            wasAgentRunning: true
        )

        func window(workspaceID: UUID, currentDirectory: String, terminal: SessionTerminalPanelSnapshot) -> SessionWindowSnapshot {
            let workspace = SessionWorkspaceSnapshot(
                workspaceId: workspaceID,
                processTitle: "Terminal",
                customTitle: nil,
                customColor: nil,
                isPinned: false,
                currentDirectory: currentDirectory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: currentDirectory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
            return SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let degraded = window(
            workspaceID: UUID(),
            currentDirectory: "/Users/danielraffel",
            terminal: degradedTerminal
        )
        let rich = window(
            workspaceID: UUID(),
            currentDirectory: projectDirectory,
            terminal: richTerminal
        )
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [degraded, rich]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        let keptWorkspace = pruned.snapshot?.windows.first?.tabManager.workspaces.first
        #expect(keptWorkspace?.currentDirectory == projectDirectory)
        #expect(keptWorkspace?.panels.first?.terminal?.workingDirectory == projectDirectory)
        #expect(keptWorkspace?.panels.first?.terminal?.resumeBinding?.cwd == projectDirectory)
    }

    @Test
    func sessionSnapshotKeepsSameSizeWindowsWhenCheckpointSetsPartiallyOverlap() {
        let projectDirectory = "/Volumes/Workshop/Code/pulp"
        let homeDirectory = "/Users/danielraffel"

        func workspace(
            id: UUID,
            checkpointID: String?,
            directory: String,
            includeBinding: Bool
        ) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let agent = checkpointID.map {
                SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: $0,
                    workingDirectory: includeBinding ? projectDirectory : nil
                )
            }
            let binding = includeBinding && checkpointID != nil
                ? SurfaceResumeBindingSnapshot(
                    kind: "codex",
                    command: "codex resume \(checkpointID!)",
                    cwd: projectDirectory,
                    checkpointId: checkpointID,
                    source: "agent-hook",
                    autoResume: true
                )
                : nil
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: agent,
                resumeBinding: binding,
                wasAgentRunning: true
            )
            return SessionWorkspaceSnapshot(
                workspaceId: id,
                processTitle: "Terminal",
                customTitle: nil,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }

        let retainedID = "01a149a7-fbec-7240-9c88-ed6faec559ca"
        let extraID = "01a149a8-00ed-7890-845c-dce07298068a"
        let degraded = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [
                    workspace(id: UUID(), checkpointID: retainedID, directory: homeDirectory, includeBinding: false),
                    workspace(id: UUID(), checkpointID: nil, directory: homeDirectory, includeBinding: false),
                ]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        let rich = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [
                    workspace(id: UUID(), checkpointID: retainedID, directory: projectDirectory, includeBinding: true),
                    workspace(id: UUID(), checkpointID: extraID, directory: projectDirectory, includeBinding: true),
                ]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )

        let pruned = pruningAndMergingCrashWindows(
            from: AppSessionSnapshot(
                version: SessionSnapshotSchema.currentVersion,
                createdAt: 10,
                windows: [degraded, rich]
            )
        )

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 2)
        #expect(pruned.snapshot?.windows.allSatisfy { $0.tabManager.workspaces.count == 2 } == true)
    }

    @Test
    func sessionSnapshotDoesNotMatchIdentityLessWorkspacesByPosition() {
        let retainedID = "01a149a7-fbec-7240-9c88-ed6faec559ca"
        let projectDirectory = "/Volumes/Workshop/Code/pulp"

        func workspace(directory: String, checkpointID: String?) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: checkpointID.map {
                    SessionRestorableAgentSnapshot(
                        kind: .codex,
                        sessionId: $0,
                        workingDirectory: projectDirectory
                    )
                },
                wasAgentRunning: checkpointID != nil
            )
            return SessionWorkspaceSnapshot(
                workspaceId: nil,
                processTitle: "Terminal",
                customTitle: nil,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }

        func window(workspaces: [SessionWorkspaceSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: 0,
                    workspaces: workspaces
                ),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                window(workspaces: [
                    workspace(directory: projectDirectory, checkpointID: retainedID),
                    workspace(directory: "/Volumes/Workshop/Code/first", checkpointID: nil),
                    workspace(directory: "/Volumes/Workshop/Code/auxiliary", checkpointID: nil),
                ]),
                window(workspaces: [
                    workspace(directory: projectDirectory, checkpointID: retainedID),
                    workspace(directory: "/Volumes/Workshop/Code/second", checkpointID: "01a149a8-00ed-7890-845c-dce07298068a"),
                    workspace(directory: "/Volumes/Workshop/Code/third", checkpointID: nil),
                ]),
            ]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 2)
        #expect(
            Set(pruned.snapshot?.windows.flatMap { $0.tabManager.workspaces.map(\.currentDirectory) } ?? []) == [
                projectDirectory,
                "/Volumes/Workshop/Code/first",
                "/Volumes/Workshop/Code/auxiliary",
                "/Volumes/Workshop/Code/second",
                "/Volumes/Workshop/Code/third",
            ]
        )
    }

    @Test
    func sessionSnapshotMergesExactAgentFingerprintAndRetainsIdentitylessWorkspaces() {
        let checkpointID = "01a149a7-fbec-7240-9c88-ed6faec559ca"

        func workspace(_ directory: String, checkpoint: String? = nil) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: checkpoint.map {
                    SessionRestorableAgentSnapshot(
                        kind: .codex,
                        sessionId: $0,
                        workingDirectory: directory
                    )
                },
                wasAgentRunning: checkpoint != nil
            )
            return SessionWorkspaceSnapshot(
                workspaceId: nil,
                processTitle: "Terminal",
                customTitle: nil,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }
        func window(_ workspaces: [SessionWorkspaceSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                window([
                    workspace("/work/project", checkpoint: checkpointID),
                    workspace("/work/first"),
                    workspace("/work/auxiliary"),
                ]),
                window([
                    workspace("/work/project", checkpoint: checkpointID),
                    workspace("/work/second"),
                    workspace("/work/third"),
                ]),
            ]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        #expect(
            Set(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.currentDirectory) ?? []) == [
                "/work/project",
                "/work/first",
                "/work/auxiliary",
                "/work/second",
                "/work/third",
            ]
        )
    }

    @Test
    func sessionSnapshotMergesReorderedTitledCrashWindowsWithoutDroppingUniqueWorkspaces() {
        func workspace(_ title: String, _ directory: String, _ checkpoint: String?) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: checkpoint.map {
                    SessionRestorableAgentSnapshot(kind: .codex, sessionId: $0, workingDirectory: directory)
                },
                wasAgentRunning: checkpoint != nil
            )
            return SessionWorkspaceSnapshot(
                workspaceId: nil,
                processTitle: "Terminal",
                customTitle: title,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }
        func window(_ workspaces: [SessionWorkspaceSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let first = window([
            workspace("A", "/work/a", "a"),
            workspace("B", "/work/b", "b"),
            workspace("C", "/work/c", "c"),
            workspace("D", "/work/d", "d"),
            workspace("E", "/work/e", nil),
        ])
        let reordered = window([
            workspace("C", "/work/c", "c"),
            workspace("A", "/work/a", "a"),
            workspace("E", "/work/e-new", "e"),
            workspace("D", "/work/d", "d"),
            workspace("B", "/work/b", "b"),
        ])

        let pruned = pruningAndMergingCrashWindows(from: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [first, reordered]
        ))

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        #expect(Set(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.customTitle) ?? []) == ["A", "B", "C", "D", "E"])
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.contains { $0.currentDirectory == "/work/e-new" } == true)
    }

    @Test
    func sessionSnapshotKeepsWorkspacelessWindowWithEmptyPinnedGroup() {
        // TabManager persists an empty pinned group even when no workspace in
        // the window is restorable; that group is user state, not a phantom.
        let group = SessionWorkspaceGroupSnapshot(
            id: UUID(),
            name: "Pinned",
            isCollapsed: false,
            anchorIsEmpty: true,
            isPinned: true
        )
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(
                        selectedWorkspaceIndex: nil,
                        workspaces: [],
                        workspaceGroups: [group]
                    ),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )

        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot)

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaceGroups?.map(\.id) == [group.id])
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

    @Test(arguments: [Float(13), Float(510)])
    func sessionSnapshotKeepsCrashWorkspaceWithValidExplicitFontSize(fontSize: Float) {
        let crashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
            .path
        let projectDirectory = "/tmp/cmux-project"
        let snapshot = crashAndProjectSnapshot(
            crashDirectory: crashDirectory,
            projectDirectory: projectDirectory,
            fontSize: fontSize
        )

        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot)

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.currentDirectory) == [
            crashDirectory,
            projectDirectory,
        ])
    }

    @Test(arguments: [Float.zero, -1, .nan, .infinity, 511, .greatestFiniteMagnitude])
    func sessionSnapshotPrunesCrashWorkspaceWithInvalidFontSize(fontSize: Float) {
        let crashDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux/crash", isDirectory: true)
            .path
        let projectDirectory = "/tmp/cmux-project"
        let snapshot = crashAndProjectSnapshot(
            crashDirectory: crashDirectory,
            projectDirectory: projectDirectory,
            fontSize: fontSize
        )

        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot)

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.first?.tabManager.workspaces.map(\.currentDirectory) == [
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

    /// Session autosave clears this marker on every write. `UserDefaults` posts
    /// `didChangeNotification` even for no-op writes, which wakes every defaults
    /// observer in the app (including SwiftUI's `@AppStorage` observer, which
    /// takes SwiftUI's global update lock). A steady-state write must stay silent.
    @Test
    func crashOnlyPrimarySnapshotRemovalMarkerSkipsNoOpDefaultsWrites() throws {
        let defaultsSuiteName = "CrashDiagnosticSessionPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
        let counter = DefaultsChangeCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        AppDelegate.clearCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)
        #expect(counter.value == 0)

        AppDelegate.markCrashOnlyPrimarySnapshotRemoval(defaults: defaults)
        #expect(counter.value == 1)
        AppDelegate.markCrashOnlyPrimarySnapshotRemoval(defaults: defaults)
        #expect(counter.value == 1)

        AppDelegate.clearCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)
        #expect(counter.value == 2)
        AppDelegate.clearCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults)
        #expect(counter.value == 2)
        #expect(!AppDelegate.hasCrashOnlyPrimarySnapshotRemovalMarker(defaults: defaults))
    }

    @Test
    func missingPrimaryRecoveryRequiresAnUncleanLaunchSignal() {
        #expect(
            !AppDelegate.shouldRecoverMissingPrimarySessionSnapshot(
                previousLaunchWasUnclean: false,
                crashOnlyPrimarySnapshotRemovalMarker: false
            )
        )
        #expect(
            AppDelegate.shouldRecoverMissingPrimarySessionSnapshot(
                previousLaunchWasUnclean: true,
                crashOnlyPrimarySnapshotRemovalMarker: false
            )
        )
        #expect(
            AppDelegate.shouldRecoverMissingPrimarySessionSnapshot(
                previousLaunchWasUnclean: false,
                crashOnlyPrimarySnapshotRemovalMarker: true
            )
        )
    }

    @Test
    func sessionLaunchSentinelClassifiesAndClearsUncleanRuns() throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-launch-state-\(UUID().uuidString)", isDirectory: true)
        let environment = ["CMUX_BUNDLE_ID": "com.cmux.tests.sentinel"]
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        #expect(
            !GhosttyCrashBreadcrumb.priorSessionLaunchWasUnclean(
                homeDirectory: homeDirectory,
                environment: environment
            )
        )
        #expect(
            !GhosttyCrashBreadcrumb.captureSessionLaunchState(
                homeDirectory: homeDirectory,
                environment: environment
            )
        )
        #expect(
            GhosttyCrashBreadcrumb.priorSessionLaunchWasUnclean(
                homeDirectory: homeDirectory,
                environment: environment
            )
        )

        // A second process would observe the first process's sentinel as an
        // unclean prior run. This is the launch classification used by startup
        // snapshot recovery.
        #expect(
            GhosttyCrashBreadcrumb.captureSessionLaunchState(
                homeDirectory: homeDirectory,
                environment: environment
            )
        )

        GhosttyCrashBreadcrumb.markSessionCleanExit(
            homeDirectory: homeDirectory,
            environment: environment
        )
        #expect(
            !GhosttyCrashBreadcrumb.priorSessionLaunchWasUnclean(
                homeDirectory: homeDirectory,
                environment: environment
            )
        )
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

    private func crashAndProjectSnapshot(
        crashDirectory: String,
        projectDirectory: String,
        fontSize: Float
    ) -> AppSessionSnapshot {
        AppSessionSnapshot(
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
                                    fontSize: fontSize
                                )
                            ),
                            emptyWorkspaceSnapshot(currentDirectory: projectDirectory),
                        ]
                    ),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
    }

    /// A crash replay seen on a test Mac (2026-10-20): the same titled
    /// workspaces in two windows with different window IDs, and every agent
    /// checkpoint of the first window also in the second.
    private func replayedWindowPair() -> (original: SessionWindowSnapshot, replay: SessionWindowSnapshot) {
        func workspace(_ title: String, checkpoints: [String]) -> SessionWorkspaceSnapshot {
            let panels = checkpoints.map { checkpoint -> SessionPanelSnapshot in
                let terminal = SessionTerminalPanelSnapshot(
                    workingDirectory: "/work/\(title)",
                    agent: SessionRestorableAgentSnapshot(
                        kind: .codex,
                        sessionId: checkpoint,
                        workingDirectory: "/work/\(title)"
                    ),
                    wasAgentRunning: true
                )
                return terminalPanelSnapshot(id: UUID(), directory: "/work/\(title)", terminal: terminal)
            }
            let first = panels.first?.id ?? UUID()
            return SessionWorkspaceSnapshot(
                workspaceId: UUID(),
                processTitle: "Terminal",
                customTitle: title,
                customColor: nil,
                isPinned: false,
                currentDirectory: "/work/\(title)",
                focusedPanelId: first,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: panels.map(\.id), selectedPanelId: first)),
                panels: panels,
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }
        func window(_ workspaces: [SessionWorkspaceSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                windowId: UUID(),
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }
        let original = window([
            workspace("api", checkpoints: ["a"]),
            workspace("docs", checkpoints: ["b"]),
            workspace("infra", checkpoints: []),
            workspace("web", checkpoints: []),
        ])
        let replay = window([
            workspace("web", checkpoints: ["d"]),
            workspace("api", checkpoints: ["a"]),
            workspace("infra", checkpoints: ["c"]),
            workspace("docs", checkpoints: ["b"]),
        ])
        return (original, replay)
    }

    private func crashTestWorkspace(
        _ title: String,
        agents: [String] = [],
        tmuxSessions: [String] = [],
        richDirectories: Bool = true
    ) -> SessionWorkspaceSnapshot {
        let directory = "/work/\(title)"
        let agentPanels = agents.map { checkpoint -> SessionPanelSnapshot in
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: richDirectories ? directory : nil,
                agent: SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: checkpoint,
                    workingDirectory: richDirectories ? directory : nil
                ),
                wasAgentRunning: true
            )
            return terminalPanelSnapshot(id: UUID(), directory: richDirectories ? directory : nil, terminal: terminal)
        }
        let tmuxPanels = tmuxSessions.map { name -> SessionPanelSnapshot in
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                resumeBinding: SurfaceResumeBindingSnapshot(
                    name: "tmux \(name)",
                    kind: "tmux",
                    command: "tmux new-session -A -s \(name)",
                    cwd: directory,
                    checkpointId: name,
                    source: "process-detected"
                )
            )
            return terminalPanelSnapshot(id: UUID(), directory: directory, terminal: terminal)
        }
        let panels = agentPanels + tmuxPanels
        let first = panels.first?.id ?? UUID()
        return SessionWorkspaceSnapshot(
            workspaceId: UUID(),
            processTitle: "Terminal",
            customTitle: title,
            customColor: nil,
            isPinned: false,
            currentDirectory: directory,
            focusedPanelId: first,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: panels.map(\.id), selectedPanelId: first)),
            panels: panels,
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
    }

    private func crashTestWindow(_ workspaces: [SessionWorkspaceSnapshot], id: UUID = UUID()) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            windowId: id,
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
    }

    /// Two real windows (a laptop screen and a monitor) can both attach the
    /// same tmux sessions, e.g. `tmux new -A -s cmux`. Multiplexer session
    /// names are meant to be shared, so they are not agent checkpoints.
    @Test
    func sessionSnapshotKeepsWindowsThatShareTmuxSessionsSeparate() {
        let titles = ["api", "docs", "infra", "web"]
        let laptop = crashTestWindow(titles.map { crashTestWorkspace($0, tmuxSessions: ["cmux", "work"]) })
        let monitor = crashTestWindow(titles.map { crashTestWorkspace($0, tmuxSessions: ["cmux", "work"]) })
        let merged = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [laptop, monitor]
        ))

        #expect(merged.mergedWindowCount == 0)
        #expect(merged.snapshot.windows.count == 2)
    }

    /// When one copy of a workspace holds every agent of the other copy and
    /// more, it wins even if the other copy scores higher on directories:
    /// otherwise an agent pane found only in the replay is dropped.
    @Test
    func sessionSnapshotKeepsTheWorkspaceCopyWithMoreAgentsWhenCrashCopiesMerge() {
        let id = UUID()
        let rich = crashTestWindow([
            crashTestWorkspace("api", agents: ["a"]),
            crashTestWorkspace("docs", agents: ["c"]),
            crashTestWorkspace("infra", agents: ["d"]),
            crashTestWorkspace("web", agents: ["e"]),
        ], id: id)
        let replay = crashTestWindow([
            crashTestWorkspace("api", agents: ["a", "b"], richDirectories: false),
            crashTestWorkspace("docs", agents: ["c"], richDirectories: false),
            crashTestWorkspace("infra", agents: ["d"], richDirectories: false),
            crashTestWorkspace("web", agents: ["e"], richDirectories: false),
        ], id: id)
        let merged = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [rich, replay]
        ))

        #expect(merged.mergedWindowCount == 1)
        let api = merged.snapshot.windows.first?.tabManager.workspaces.first { $0.customTitle == "api" }
        #expect(Set(api?.panels.compactMap { $0.terminal?.agent?.sessionId } ?? []) == ["a", "b"])
        #expect(merged.snapshot.windows.first?.tabManager.workspaces.count == 4)
    }

    /// Every live restore (startup, its history fallback, manual reopen and
    /// import) goes through `snapshotForLiveRestore`: it merges duplicates,
    /// and scrollback recovery runs before the merge so the winning copy
    /// keeps the recovered scrollback.
    @Test
    func liveRestoreSnapshotMergesAfterRecoveringScrollback() {
        let pair = replayedWindowPair()
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [pair.original, pair.replay]
        )
        var recoveredWindowCount: Int?
        let restored = SessionPersistencePolicy.snapshotForLiveRestore(snapshot) { pruned in
            recoveredWindowCount = pruned.windows.count
            var recovered = pruned
            for windowIndex in recovered.windows.indices {
                for workspaceIndex in recovered.windows[windowIndex].tabManager.workspaces.indices {
                    for panelIndex in recovered.windows[windowIndex].tabManager.workspaces[workspaceIndex].panels.indices {
                        recovered.windows[windowIndex].tabManager.workspaces[workspaceIndex]
                            .panels[panelIndex].terminal?.scrollback = "recovered"
                    }
                }
            }
            return recovered
        }

        #expect(recoveredWindowCount == 2)
        #expect(restored?.windows.count == 1)
        let panels = restored?.windows.first?.tabManager.workspaces.flatMap(\.panels) ?? []
        #expect(!panels.isEmpty)
        #expect(panels.allSatisfy { $0.terminal == nil || $0.terminal?.scrollback == "recovered" })
    }

    @Test
    func liveRestoreSnapshotCollapsesThreeCopiesOfAWindow() {
        let pair = replayedWindowPair()
        var third = pair.replay
        third.windowId = UUID()
        let restored = SessionPersistencePolicy.snapshotForLiveRestore(AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [pair.original, pair.replay, third]
        ))

        #expect(restored?.windows.count == 1)
        #expect(restored?.windows.first?.tabManager.workspaces.count == 4)
    }

    @Test
    func sessionSnapshotMergesACrashReplayedWindowWithANewWindowID() {
        let pair = replayedWindowPair()
        let merged = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [pair.original, pair.replay]
        ))

        #expect(merged.mergedWindowCount == 1)
        let windows = merged.snapshot.windows
        #expect(windows.count == 1)
        let titles = windows.first?.tabManager.workspaces.compactMap(\.customTitle) ?? []
        #expect(titles.sorted() == ["api", "docs", "infra", "web"])
        let checkpoints = Set(windows.first?.tabManager.workspaces.flatMap { workspace in
            workspace.panels.compactMap { $0.terminal?.agent?.sessionId }
        } ?? [])
        #expect(checkpoints == ["a", "b", "c", "d"])
    }

    /// The manual-restore sync writes `pruningCmuxCrashDiagnosticWindows`'s
    /// result into the `-previous` backup on every launch, so that path must
    /// keep both copies: a wrong merge then never replaces the only good one.
    @Test
    func crashPruningKeepsBothCopiesOfAReplayedWindowForTheBackup() {
        let pair = replayedWindowPair()
        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [pair.original, pair.replay]
        ))

        #expect(pruned.snapshot?.windows.count == 2)
        let expectedIDs = Set([pair.original.windowId, pair.replay.windowId].compactMap { $0 })
        #expect(Set(pruned.snapshot?.windows.compactMap(\.windowId) ?? []) == expectedIDs)
    }

    @Test
    func sessionSnapshotKeepsDistinctPersistedWindowsWithOverlappingAgentsSeparate() {
        func workspace(_ directory: String, checkpoint: String) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: SessionRestorableAgentSnapshot(
                    kind: .codex,
                    sessionId: checkpoint,
                    workingDirectory: directory
                ),
                wasAgentRunning: true
            )
            return SessionWorkspaceSnapshot(
                workspaceId: nil,
                processTitle: "Terminal",
                customTitle: nil,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }
        func window(_ id: UUID, directory: String) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                windowId: id,
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: 0,
                    workspaces: [workspace(directory, checkpoint: "shared")]
                ),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let pruned = pruningAndMergingCrashWindows(from: AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                window(firstWindowID, directory: "/work/first-window"),
                window(secondWindowID, directory: "/work/second-window"),
            ]
        ))

        #expect(!pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 2)
        #expect(Set(pruned.snapshot?.windows.flatMap { $0.tabManager.workspaces.map(\.currentDirectory) } ?? []) == [
            "/work/first-window", "/work/second-window",
        ])
    }

    @Test
    func sessionSnapshotKeepsSameTitleWorkspacesWithDifferentDirectoriesSeparate() {
        func workspace(
            title: String?,
            directory: String,
            checkpoint: String? = nil
        ) -> SessionWorkspaceSnapshot {
            let panelID = UUID()
            let terminal = SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: checkpoint.map {
                    SessionRestorableAgentSnapshot(
                        kind: .codex,
                        sessionId: $0,
                        workingDirectory: directory
                    )
                },
                wasAgentRunning: checkpoint != nil
            )
            return SessionWorkspaceSnapshot(
                workspaceId: nil,
                processTitle: "Terminal",
                customTitle: title,
                customColor: nil,
                isPinned: false,
                currentDirectory: directory,
                focusedPanelId: panelID,
                layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelID], selectedPanelId: panelID)),
                panels: [terminalPanelSnapshot(id: panelID, directory: directory, terminal: terminal)],
                statusEntries: [],
                logEntries: [],
                progress: nil,
                gitBranch: nil
            )
        }
        func window(_ workspaces: [SessionWorkspaceSnapshot]) -> SessionWindowSnapshot {
            SessionWindowSnapshot(
                frame: nil,
                display: nil,
                tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )
        }

        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 10,
            windows: [
                window([
                    workspace(title: "anchor", directory: "/work/anchor", checkpoint: "shared"),
                    workspace(title: "same-title", directory: "/work/one"),
                ]),
                window([
                    workspace(title: "anchor", directory: "/work/anchor", checkpoint: "shared"),
                    workspace(title: "same-title", directory: "/work/two"),
                ]),
            ]
        )

        let pruned = pruningAndMergingCrashWindows(from: snapshot)
        let workspaces = pruned.snapshot?.windows.first?.tabManager.workspaces ?? []

        #expect(pruned.removedAny)
        #expect(pruned.snapshot?.windows.count == 1)
        #expect(Set(workspaces.map(\.currentDirectory)) == [
            "/work/anchor", "/work/one", "/work/two",
        ])
    }

    private func terminalPanelSnapshot(
        id: UUID,
        directory: String?,
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

// The immutable DispatchSpecificKey lacks Sendable annotation; observed contexts
// are protected by the lock. No store state is accessed without that lock.
private final class PersistenceQueueProbeStore: SessionSnapshotStoring, @unchecked Sendable {
    typealias SnapshotValue = AppSessionSnapshot
    private let key: DispatchSpecificKey<Bool>
    private let lock = NSLock()
    private var recordedContexts: [Bool] = []

    init(key: DispatchSpecificKey<Bool>) { self.key = key }
    var contexts: [Bool] { lock.withLock { recordedContexts } }

    func removeSnapshot(fileURL: URL?) {
        let isOnPersistenceQueue = DispatchQueue.getSpecific(key: key) == true
        lock.withLock { recordedContexts.append(isOnPersistenceQueue) }
    }

    func save(_ snapshot: AppSessionSnapshot, fileURL: URL?) -> Bool { false }
    func loadOutcome(fileURL: URL) -> SessionSnapshotLoadOutcome<AppSessionSnapshot> { .missing }
    func load(fileURL: URL?) -> AppSessionSnapshot? { nil }
    func loadReopenSessionSnapshot(fileURL: URL?) -> AppSessionSnapshot? { nil }
    func syncManualRestoreSnapshotCache() {}
    func loadStartupSnapshot() -> AppSessionSnapshot? { nil }
    func defaultSnapshotFileURL() -> URL? { nil }
    func manualRestoreSnapshotFileURL() -> URL? { nil }
    func snapshotFileURL(bundleIdentifier: String) -> URL? { nil }
    func importableSnapshot(
        fileURL: URL
    ) -> Result<SessionSnapshotImport<AppSessionSnapshot>, SessionSnapshotImportError> {
        .failure(.fileNotFound(fileURL))
    }
    func importableSnapshot(
        bundleIdentifier: String
    ) -> Result<SessionSnapshotImport<AppSessionSnapshot>, SessionSnapshotImportError> {
        .failure(.fileNotFound(URL(fileURLWithPath: "/dev/null")))
    }
    func exportSnapshot(to destination: URL, overwrite: Bool) -> Result<URL, SessionSnapshotExportError> {
        .failure(.noSnapshot)
    }
    func preserveNewerSchemaSnapshot(fileURL: URL) -> URL? { nil }
    func preserveNewerSchemaSnapshotBeforeReplacing(fileURL: URL) -> Bool { true }
    func preserveUnusableSnapshot(fileURL: URL) -> URL? { nil }
    func archiveSnapshotToHistory(
        fileURL: URL,
        richness: SessionSnapshotRichness,
        archivedAt: Date
    ) -> SessionSnapshotHistoryEntry? { nil }
    func historyEntries() -> [SessionSnapshotHistoryEntry] { [] }
}

extension CrashDiagnosticSessionPolicyTests {
    @Test("Shutdown persistence shares the autosave serial executor")
    func synchronousPersistenceUsesAutosaveQueue() throws {
        let queue = DispatchQueue(label: "cmux.tests.snapshot-persistence")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let store = PersistenceQueueProbeStore(key: key)
        // Isolated defaults: the empty-snapshot path clears the crash-only
        // marker and legacy geometry keys, which must not touch shared state.
        let suiteName = "cmux.tests.snapshot-persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = SessionSnapshotPersistenceWriter(store: store, queue: queue, defaults: defaults)

        writer.persist(nil, removeWhenEmpty: true, persistedGeometryData: nil, synchronously: true)
        #expect(store.contexts == [true])
        writer.persist(nil, removeWhenEmpty: true, persistedGeometryData: nil, synchronously: false)
        queue.sync {}
        #expect(store.contexts == [true, true])
    }
}

/// Counts `UserDefaults.didChangeNotification` deliveries from a synchronous observer.
private final class DefaultsChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Prunes crash-diagnostic windows, then merges crash-duplicate windows, the
/// way `SessionPersistencePolicy.snapshotForLiveRestore` does at live
/// restore. `removedAny` is true when pruning dropped a window or merging
/// collapsed one, so a test of either can assert it.
private func pruningAndMergingCrashWindows(
    from snapshot: AppSessionSnapshot
) -> (snapshot: AppSessionSnapshot?, removedAny: Bool) {
    let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot)
    guard let prunedSnapshot = pruned.snapshot else { return (nil, pruned.removedAny) }
    let merged = SessionPersistencePolicy.mergingCrashDuplicateWindows(in: prunedSnapshot)
    return (merged.snapshot, pruned.removedAny || merged.mergedWindowCount > 0)
}
