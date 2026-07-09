import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct NotesTreeStorageTerminalObservationTests {
    let projectRoot: String
    private let fm = FileManager.default

    init() throws {
        projectRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cmux-notes-tree-\(UUID().uuidString)")
        try fm.createDirectory(atPath: projectRoot, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, to path: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test @MainActor func terminalRowsNestAnchoredNotesAndOnlyObservedSessions() async throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-term"
        )
        let notesDir = NoteSupport.notesDirectory(forProjectRoot: projectRoot)
        struct IndexFixture: Codable {
            var version = 1
            var notes: [CmuxNoteRecord]
        }
        let fixture = IndexFixture(notes: [
            CmuxNoteRecord(
                id: "pane",
                slug: "pane-note",
                title: "Pane note",
                bodyPath: "notes/pane.md",
                attachments: [
                    CmuxNoteAttachment(
                        kind: .surface,
                        workspaceAnchorId: "anchor-term",
                        surfaceAnchorId: "anchor-pane-1",
                        surfaceKind: "terminal",
                        createdAt: 1
                    )
                ],
                createdAt: 1,
                updatedAt: 2
            )
        ])
        try JSONEncoder().encode(fixture).write(
            to: URL(fileURLWithPath: (notesDir as NSString).appendingPathComponent("index.json"))
        )
        try write("pane body", to: (notesDir as NSString).appendingPathComponent("pane.md"))
        _ = NotesTreeStorage.updateWorkspaceSessions(
            inRoot: root,
            observed: [
                NotesTreeObservedSession(agent: "claude", sessionId: "s-term", surfaceAnchorId: "anchor-pane-1")
            ],
            live: [],
            now: 100
        )

        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-term"
        )
        store.applyObservedTerminals([
            NotesTreeObservedTerminal(panelId: UUID().uuidString, anchorId: "anchor-pane-1", title: "build shell"),
            NotesTreeObservedTerminal(panelId: UUID().uuidString, anchorId: nil, title: "scratch")
        ])
        await store.waitForPendingReloadForTesting()

        // Both terminals appear, in pane order, as virtual rows.
        let terminalRows = store.rootNodes.compactMap { node in
            node.kind.terminalMarker.map { (node: node, marker: $0) }
        }
        #expect(terminalRows.map { $0.marker.title } == ["build shell", "scratch"])
        #expect(terminalRows.allSatisfy { $0.node.isVirtual })

        // With no live session observation yet, the anchored pane note belongs
        // to the historical session under Past rather than to the plain
        // terminal row.
        let anchored = try #require(terminalRows.first { $0.marker.anchorId == "anchor-pane-1" })
        let children = anchored.node.children ?? []
        #expect(!children.contains { $0.displayName == "Pane note" })
        #expect(!children.contains { $0.kind.sessionMarker?.sessionId == "s-term" })
        let past = try #require(store.rootNodes.first { $0.kind == .pastFolder })
        let pastSession = try #require((past.children ?? []).first { $0.kind.sessionMarker?.sessionId == "s-term" })
        #expect((pastSession.children ?? []).contains { $0.displayName == "Pane note" })

        // … and neither the pane note nor the historical session floats at the root.
        #expect(!store.rootNodes.contains { $0.displayName == "Pane note" })
        #expect(!store.rootNodes.contains { $0.kind.sessionMarker?.sessionId == "s-term" })

        store.applyObservedSessions([
            NotesTreeObservedSession(
                agent: "claude",
                sessionId: "s-term",
                surfaceAnchorId: "anchor-pane-1",
                terminalPanelId: anchored.marker.panelId
            )
        ])
        await store.waitForPendingReloadForTesting()
        let refreshedTerminalRows = store.rootNodes.compactMap { node in
            node.kind.terminalMarker.map { (node: node, marker: $0) }
        }
        let refreshedAnchored = try #require(refreshedTerminalRows.first { $0.marker.anchorId == "anchor-pane-1" })
        #expect(refreshedAnchored.node.displayName == "Claude Code")
        #expect(refreshedAnchored.marker.activeSession?.sessionId == "s-term")
        #expect((refreshedAnchored.node.children ?? []).contains { $0.displayName == "Pane note" })
        #expect(!(refreshedAnchored.node.children ?? []).contains { $0.kind.sessionMarker?.sessionId == "s-term" })
        #expect(!store.rootNodes.contains { $0.kind == .pastFolder })

        // The anchorless terminal stays an empty pointer row.
        let bare = try #require(refreshedTerminalRows.first { $0.marker.anchorId == nil })
        #expect((bare.node.children ?? []).isEmpty)
        #expect(!bare.node.isExpandable)

        // When the session exits, the terminal goes back to its shell title
        // and the session plus its note return to Past.
        store.applyObservedSessions([])
        await store.waitForPendingReloadForTesting()
        let endedTerminalRows = store.rootNodes.compactMap { node in
            node.kind.terminalMarker.map { (node: node, marker: $0) }
        }
        let endedAnchored = try #require(endedTerminalRows.first { $0.marker.anchorId == "anchor-pane-1" })
        #expect(endedAnchored.node.displayName == "build shell")
        #expect(!(endedAnchored.node.children ?? []).contains { $0.displayName == "Pane note" })
        let endedPast = try #require(store.rootNodes.first { $0.kind == .pastFolder })
        let endedPastSession = try #require((endedPast.children ?? []).first { $0.kind.sessionMarker?.sessionId == "s-term" })
        #expect((endedPastSession.children ?? []).contains { $0.displayName == "Pane note" })
    }

    @Test @MainActor func terminalRowsReflectActiveAgentSessionAndRevertWhenItEnds() async throws {
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-active"
        )
        let panelId = UUID().uuidString
        store.applyObservedTerminals([
            NotesTreeObservedTerminal(panelId: panelId, anchorId: nil, title: "zsh")
        ])
        await store.waitForPendingReloadForTesting()
        var row = try #require(store.rootNodes.first { $0.kind.terminalMarker?.panelId == panelId })
        #expect(row.displayName == "zsh")
        #expect(row.kind.terminalMarker?.activeSession == nil)

        store.applyObservedSessions([
            NotesTreeObservedSession(
                agent: "claude",
                sessionId: "s-active",
                surfaceAnchorId: nil,
                terminalPanelId: panelId
            )
        ])
        await store.waitForPendingReloadForTesting()
        row = try #require(store.rootNodes.first { $0.kind.terminalMarker?.panelId == panelId })
        #expect(row.displayName == "Claude Code")
        #expect(row.kind.terminalMarker?.activeSession?.sessionId == "s-active")

        store.applyObservedSessions([])
        await store.waitForPendingReloadForTesting()
        row = try #require(store.rootNodes.first { $0.kind.terminalMarker?.panelId == panelId })
        #expect(row.displayName == "zsh")
        #expect(row.kind.terminalMarker?.activeSession == nil)
    }

    @Test @MainActor func observedTerminalTitleChangesRefreshRows() async throws {
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-title"
        )
        let panelId = UUID().uuidString

        store.applyObservedTerminals([
            NotesTreeObservedTerminal(panelId: panelId, anchorId: "anchor-pane", title: "old title")
        ])
        await store.waitForPendingReloadForTesting()
        #expect(store.rootNodes.compactMap(\.kind.terminalMarker).map(\.title) == ["old title"])

        store.applyObservedTerminals([
            NotesTreeObservedTerminal(panelId: panelId, anchorId: "anchor-pane", title: "new title")
        ])
        await store.waitForPendingReloadForTesting()
        #expect(store.rootNodes.compactMap(\.kind.terminalMarker).map(\.title) == ["new title"])
    }

    @Test @MainActor func droppingTreeNoteOnTerminalFilesItUnderTerminalAnchor() async throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-drop"
        )
        let looseNote = try NotesTreeStorage.newNote(inFolder: root, preferredName: "Loose Note")
        try write("# loose", to: looseNote)

        let terminal = NotesTreeObservedTerminal(
            panelId: UUID().uuidString,
            anchorId: "anchor-pane-drop",
            title: "target terminal"
        )
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-drop"
        )
        store.applyObservedTerminals([terminal])

        let target = CmuxNoteAttachmentTarget.surface(
            workspaceAnchorId: "anchor-drop",
            surfaceAnchorId: "anchor-pane-drop",
            surfaceKind: PanelType.terminal.rawValue
        )
        let filedPath = try #require(store.attachNote(path: looseNote, toTerminal: terminal, target: target))
        await store.waitForPendingReloadForTesting()
        #expect(!fm.fileExists(atPath: looseNote))
        #expect(fm.fileExists(atPath: filedPath))

        let record = try #require(try CmuxNoteStore.list(projectRoot: projectRoot).first)
        #expect(CmuxNoteStore.noteBodyPath(for: record, projectRoot: projectRoot) == filedPath)
        #expect(record.attachments.contains { $0.matches(target) })

        let terminalRow = try #require(store.rootNodes.first { $0.kind.terminalMarker?.panelId == terminal.panelId })
        let children = terminalRow.children ?? []
        #expect(children.contains { $0.path == filedPath && $0.displayName == record.title })
        #expect(!store.rootNodes.contains { $0.path == filedPath })
    }

    @Test @MainActor func droppingIndexedNoteOnAnotherTerminalReplacesWorkspaceAttachment() async throws {
        _ = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-move"
        )
        let firstTarget = CmuxNoteAttachmentTarget.surface(
            workspaceAnchorId: "anchor-move",
            surfaceAnchorId: "anchor-pane-a",
            surfaceKind: PanelType.terminal.rawValue
        )
        let secondTarget = CmuxNoteAttachmentTarget.surface(
            workspaceAnchorId: "anchor-move",
            surfaceAnchorId: "anchor-pane-b",
            surfaceKind: PanelType.terminal.rawValue
        )
        let created = try CmuxNoteStore.createOrOpen(
            slug: "pane-note",
            title: "Pane note",
            projectRoot: projectRoot,
            createIfMissing: true,
            attachment: firstTarget
        )
        let first = NotesTreeObservedTerminal(
            panelId: UUID().uuidString,
            anchorId: "anchor-pane-a",
            title: "first terminal"
        )
        let second = NotesTreeObservedTerminal(
            panelId: UUID().uuidString,
            anchorId: "anchor-pane-b",
            title: "second terminal"
        )
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-move"
        )
        store.applyObservedTerminals([first, second])

        let filedPath = try #require(store.attachNote(path: created.path, toTerminal: second, target: secondTarget))
        await store.waitForPendingReloadForTesting()
        #expect(filedPath == created.path)
        let record = try #require(try CmuxNoteStore.list(projectRoot: projectRoot).first { $0.slug == "pane-note" })
        #expect(record.attachments.contains { $0.matches(secondTarget) })
        #expect(!record.attachments.contains { $0.matches(firstTarget) })

        let firstRow = try #require(store.rootNodes.first { $0.kind.terminalMarker?.panelId == first.panelId })
        let secondRow = try #require(store.rootNodes.first { $0.kind.terminalMarker?.panelId == second.panelId })
        #expect(!(firstRow.children ?? []).contains { $0.path == created.path })
        #expect((secondRow.children ?? []).contains { $0.path == created.path })
    }

    @Test @MainActor func workspaceTerminalMetadataChangesPostNotesRefreshNotification() throws {
        let defaults = UserDefaults.standard
        let previousNotes = defaults.object(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        defer {
            if let previousNotes {
                defaults.set(previousNotes, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            } else {
                defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            }
        }
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        var observedPanelIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: .workspaceNotesTreeTerminalMetadataDidChange,
            object: workspace,
            queue: nil
        ) { notification in
            if let panelId = notification.userInfo?["panelId"] as? UUID {
                observedPanelIds.append(panelId)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "runtime title"))
        #expect(workspace.notesTreeObservedTerminals().first?.title == "runtime title")
        workspace.setPanelCustomTitle(panelId: panelId, title: "custom title")
        #expect(workspace.notesTreeObservedTerminals().first?.title == "custom title")
        _ = workspace.noteAnchorId(forPanelId: panelId)
        _ = workspace.recordAgentPID(key: "claude", pid: 12_345, panelId: panelId)
        _ = workspace.clearAgentPID(key: "claude", panelId: panelId, clearStatus: true)

        #expect(observedPanelIds == [panelId, panelId, panelId, panelId, panelId])
    }

    @Test @MainActor func workspaceTerminalMetadataNotificationsAreNotesBetaGated() throws {
        let defaults = UserDefaults.standard
        let previousNotes = defaults.object(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        defaults.set(false, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
        defer {
            if let previousNotes {
                defaults.set(previousNotes, forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            } else {
                defaults.removeObject(forKey: RightSidebarBetaFeatureSettings.notesEnabledKey)
            }
        }
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        var observedPanelIds: [UUID] = []
        let token = NotificationCenter.default.addObserver(
            forName: .workspaceNotesTreeTerminalMetadataDidChange,
            object: workspace,
            queue: nil
        ) { notification in
            if let panelId = notification.userInfo?["panelId"] as? UUID {
                observedPanelIds.append(panelId)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        #expect(workspace.updatePanelTitle(panelId: panelId, title: "beta off title"))
        _ = workspace.noteAnchorId(forPanelId: panelId)
        _ = workspace.recordAgentPID(key: "claude", pid: 12_346, panelId: panelId)
        _ = workspace.clearAgentPID(key: "claude", panelId: panelId, clearStatus: true)

        #expect(observedPanelIds.isEmpty)
    }

    /// Note classification (which enables implicit autosave) must reject
    /// symlinked note files and untrusted roots — a committed
    /// `.cmux/notes/x.md -> elsewhere` must stay a plain markdown file.
    @Test @MainActor func noteClassificationRejectsSymlinkedPaths() throws {
        let notesDir = (projectRoot as NSString).appendingPathComponent(".cmux/notes")
        try fm.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
        let real = (notesDir as NSString).appendingPathComponent("real.md")
        try write("note", to: real)
        #expect(MarkdownPanel.isWorkspaceNotesPath(real))

        let outside = (projectRoot as NSString).appendingPathComponent("victim2.md")
        try write("secret", to: outside)
        let link = (notesDir as NSString).appendingPathComponent("trap.md")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: outside)
        #expect(!MarkdownPanel.isWorkspaceNotesPath(link))
        #expect(!MarkdownPanel.isWorkspaceNotesPath(outside))
    }

    /// Note classification must also reject everything that is not a visible
    /// `.md` body: cmux metadata (`index.json`, tree markers), hidden
    /// components, non-markdown files, and the notes root itself — otherwise
    /// opening them in a markdown panel would enable implicit autosave over
    /// cmux metadata.
    @Test @MainActor func noteClassificationRejectsMetadataAndNonMarkdownPaths() throws {
        let notesDir = (projectRoot as NSString).appendingPathComponent(".cmux/notes")
        try fm.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
        for name in ["index.json", "_workspace.json", "_session.json", ".hidden.md", "todo.txt"] {
            let path = (notesDir as NSString).appendingPathComponent(name)
            try write("content", to: path)
            #expect(!MarkdownPanel.isWorkspaceNotesPath(path), "\(name) must not classify as a note")
        }
        #expect(!MarkdownPanel.isWorkspaceNotesPath(notesDir))

        let folder = (notesDir as NSString).appendingPathComponent("folder")
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let nestedMarker = (folder as NSString).appendingPathComponent("_session.json")
        try write("{}", to: nestedMarker)
        #expect(!MarkdownPanel.isWorkspaceNotesPath(nestedMarker))
        let nested = (folder as NSString).appendingPathComponent("real.md")
        try write("note", to: nested)
        #expect(MarkdownPanel.isWorkspaceNotesPath(nested))
    }

    /// Hookless (anonymous) agent observations carry only an executable name
    /// and a start time, so they may bind a session only when exactly one
    /// live session matches; two same-agent sessions in one cwd must fail
}
