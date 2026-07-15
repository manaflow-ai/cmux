import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct NotesTreeStorageStoreMutationTests {
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

    @Test func sessionMarkerRefreshTracksLiveSessionData() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        // A session dragged in long ago, nested inside a plain folder (the
        // refresh walk must find session folders at any depth)…
        let sub = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "research")
        let dragged = try #require(NotesTreeStorage.createSessionFolder(
            inFolder: sub,
            descriptor: NotesSessionDescriptor(
                agent: "claude", sessionId: "s-live", title: "Old title", cwd: "/work", modified: 100
            )
        ))
        // …and one whose session no longer exists anywhere.
        let orphan = try #require(NotesTreeStorage.createSessionFolder(
            inFolder: root,
            descriptor: NotesSessionDescriptor(
                agent: "codex", sessionId: "s-gone", title: "Orphan", cwd: "/work", modified: 50
            )
        ))

        let folders = NotesTreeStorage.collectSessionFolders(inRoot: root)
        #expect(Set(folders.map(\.marker.sessionId)) == ["s-live", "s-gone"])

        // The live scan resolved a newer title/recency for s-live (and knows
        // nothing about s-gone). Same-id-different-agent must not match.
        let changed = NotesTreeStorage.applySessionRefresh(
            folders: folders,
            live: [
                NotesSessionDescriptor(agent: "claude", sessionId: "s-live", title: "Fresh title", cwd: "/work", modified: 200),
                NotesSessionDescriptor(agent: "grok", sessionId: "s-gone", title: "Imposter", cwd: "/work", modified: 999),
            ]
        )
        #expect(changed)
        let refreshed = try #require(NotesTreeStorage.sessionMarker(inDirectory: dragged))
        #expect(refreshed.title == "Fresh title")
        #expect(refreshed.modified == 200)
        let untouched = try #require(NotesTreeStorage.sessionMarker(inDirectory: orphan))
        #expect(untouched.title == "Orphan")
        #expect(untouched.modified == 50)

        // Idempotent: applying the same live data again rewrites nothing (a
        // rewrite would bump mtimes and storm the folder watchers).
        let secondPass = NotesTreeStorage.applySessionRefresh(
            folders: NotesTreeStorage.collectSessionFolders(inRoot: root),
            live: [
                NotesSessionDescriptor(agent: "claude", sessionId: "s-live", title: "Fresh title", cwd: "/work", modified: 200)
            ]
        )
        #expect(!secondPass)

        // A live entry with a blank title refreshes recency but keeps the
        // last good title.
        let blankTitle = NotesTreeStorage.applySessionRefresh(
            folders: NotesTreeStorage.collectSessionFolders(inRoot: root),
            live: [
                NotesSessionDescriptor(agent: "claude", sessionId: "s-live", title: "   ", cwd: "/work", modified: 300)
            ]
        )
        #expect(blankTitle)
        let kept = try #require(NotesTreeStorage.sessionMarker(inDirectory: dragged))
        #expect(kept.title == "Fresh title")
        #expect(kept.modified == 300)
    }

    @Test func sessionFolderCollectionRejectsSymlinkedRoot() throws {
        let outside = (projectRoot as NSString).appendingPathComponent("outside-sessions")
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let linkedRoot = (projectRoot as NSString).appendingPathComponent("linked-workspace-root")
        let externalSession = try #require(NotesTreeStorage.createSessionFolder(
            inFolder: outside,
            descriptor: NotesSessionDescriptor(
                agent: "claude",
                sessionId: "s-linked",
                title: "Linked",
                cwd: "/outside",
                modified: 100
            )
        ))
        try fm.createSymbolicLink(atPath: linkedRoot, withDestinationPath: outside)

        #expect(NotesTreeStorage.collectSessionFolders(inRoot: linkedRoot).isEmpty)
        #expect(!NotesTreeStorage.applySessionRefresh(
            folders: NotesTreeStorage.collectSessionFolders(inRoot: linkedRoot),
            live: [
                NotesSessionDescriptor(
                    agent: "claude",
                    sessionId: "s-linked",
                    title: "Should Not Write",
                    cwd: "/outside",
                    modified: 200
                )
            ]
        ))
        let marker = try #require(NotesTreeStorage.sessionMarker(inDirectory: externalSession))
        #expect(marker.title == "Linked")
        #expect(marker.modified == 100)
    }

    @Test func sessionEntryBoundaryRejectsShellMetacharacterIds() throws {
        // Markers and the session-drag pasteboard are attacker-influenceable,
        // and resume commands splice the session id into shell input.
        let bad = NotesSessionMarker(
            agent: "claude",
            sessionId: "abc; rm -rf ~",
            cwd: "/work",
            title: "x",
            modified: 1,
            userCreated: nil
        )
        #expect(bad.makeSessionEntry() == nil)
        let good = NotesSessionMarker(
            agent: "claude",
            sessionId: "0f3c2a1b-1234-4cde-9f00-aa11bb22cc33",
            cwd: "/work",
            title: "x",
            modified: 1,
            userCreated: nil
        )
        #expect(good.makeSessionEntry()?.sessionId == "0f3c2a1b-1234-4cde-9f00-aa11bb22cc33")
    }

    @Test @MainActor func storeMoveRejectsSourcesOutsideNotesDirectory() throws {
        // The move pasteboard type is globally forgeable; a crafted payload
        // must not be able to relocate arbitrary user files into the project.
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-sec"
        )
        let outside = (projectRoot as NSString).appendingPathComponent("victim.txt")
        try write("secret", to: outside)
        let dest = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-sec"
        )
        #expect(store.move(sourcePath: outside, intoFolder: dest) == nil)
        #expect(fm.fileExists(atPath: outside))
        // Tree-owned moves still work.
        let note = try NotesTreeStorage.newNote(inFolder: dest, preferredName: "inside")
        let sub = try NotesTreeStorage.newFolder(inFolder: dest, preferredName: "sub")
        #expect(store.move(sourcePath: note, intoFolder: sub) != nil)
    }

    @Test @MainActor func storeMutationsRejectHiddenNotesMetadata() throws {
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-meta"
        )
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-meta"
        )
        let notesDir = NoteSupport.notesDirectory(forProjectRoot: projectRoot)
        let index = (notesDir as NSString).appendingPathComponent("index.json")
        let workspaceMarker = (root as NSString).appendingPathComponent(NotesTreeStorage.workspaceMarkerName)
        let hidden = (root as NSString).appendingPathComponent(".hidden.md")
        try write("{}", to: index)
        try write("{}", to: workspaceMarker)
        try write("secret", to: hidden)

        #expect(store.move(sourcePath: index, intoFolder: root) == nil)
        #expect(store.rename(path: workspaceMarker, toName: "renamed") == nil)
        store.delete(path: hidden)
        #expect(fm.fileExists(atPath: index))
        #expect(fm.fileExists(atPath: workspaceMarker))
        #expect(fm.fileExists(atPath: hidden))
    }

    /// A non-nil mutation destination outside the workspace root (a stale
    /// path, the flat `.cmux/notes` area, or anywhere else) must fail the
    /// mutation — regression for `ensureRoot(folder:)` silently retargeting
    /// invalid destinations at the workspace root.
    @Test @MainActor func storeMutationsRejectDestinationsOutsideWorkspaceRoot() throws {
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-dest"
        )
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-dest"
        )
        let notesDir = NoteSupport.notesDirectory(forProjectRoot: projectRoot)
        let outside = (projectRoot as NSString).appendingPathComponent("elsewhere")
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let descriptor = NotesSessionDescriptor(
            agent: "claude",
            sessionId: "0f3c2a1b-1234-4cde-9f00-aa11bb22cc33",
            title: "session",
            cwd: "/work",
            modified: 1
        )

        #expect(store.newNote(inFolder: notesDir) == nil)
        #expect(store.newNote(inFolder: outside) == nil)
        #expect(store.newFolder(inFolder: notesDir) == nil)
        #expect(store.addSession(descriptor, intoFolder: outside) == nil)
        // Nothing may have landed at the workspace root as a fallback.
        #expect(try Set(fm.contentsOfDirectory(atPath: root)) == [NotesTreeStorage.workspaceMarkerName])
        #expect(try fm.contentsOfDirectory(atPath: outside).isEmpty)

        // The root itself and folders inside it remain valid destinations.
        #expect(store.newNote(inFolder: root) != nil)
        let sub = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "sub")
        #expect(store.newNote(inFolder: sub) != nil)
    }

    /// An indexed note filed into the tree must keep its index record through
    /// later tree moves, folder renames, and deletes — regression for raw
    /// FileManager tree operations silently orphaning `index.json` bodyPaths.
    @Test @MainActor func treeMovesKeepIndexedNoteRecordsInSync() throws {
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-idx"
        )
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-idx"
        )
        let created = try CmuxNoteStore.createOrOpen(
            slug: "tracked", projectRoot: projectRoot, createIfMissing: true
        )
        _ = created
        let folderA = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "a")
        let folderB = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "b")

        // File the indexed note into the tree (what dropping a flat note does).
        let inA = try CmuxNoteStore.relocateBody(
            slug: "tracked", projectRoot: projectRoot, toDirectory: folderA
        )
        func indexedPath() throws -> String {
            let record = try #require(
                try CmuxNoteStore.list(projectRoot: projectRoot).first { $0.slug == "tracked" }
            )
            return CmuxNoteStore.noteBodyPath(for: record, projectRoot: projectRoot)
        }
        #expect(try indexedPath() == (inA as NSString).standardizingPath)

        // A later in-tree move of the note follows in the index.
        let inB = try #require(store.move(sourcePath: inA, intoFolder: folderB))
        #expect(try indexedPath() == (inB as NSString).standardizingPath)
        #expect(fm.fileExists(atPath: try indexedPath()))

        // Renaming the folder above it rebase-rewrites the record too.
        let renamedFolder = try #require(store.rename(path: folderB, toName: "b-renamed"))
        #expect(try indexedPath().hasPrefix((renamedFolder as NSString).standardizingPath + "/"))
        #expect(fm.fileExists(atPath: try indexedPath()))

        // Deleting the folder removes the record with the body.
        store.delete(path: renamedFolder)
        #expect(try CmuxNoteStore.list(projectRoot: projectRoot).first { $0.slug == "tracked" } == nil)
    }

    /// Moving an index-owned pane note out of a terminal row and into the
    /// workspace tree must keep showing the record title, not the UUID body
    /// filename that backs the flat note store.
    @Test @MainActor func movedIndexedNoteKeepsRecordTitleInTree() async throws {
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-display"
        )
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-display"
        )
        let target = CmuxNoteAttachmentTarget.surface(
            workspaceAnchorId: "anchor-display",
            surfaceAnchorId: "anchor-pane-display",
            surfaceKind: PanelType.terminal.rawValue
        )
        let created = try CmuxNoteStore.createOrOpen(
            slug: "pane-title",
            title: "Pane Title",
            projectRoot: projectRoot,
            createIfMissing: true,
            attachment: target
        )
        let moved = try #require(store.moveFlatNote(path: created.path, intoFolder: root))
        await store.waitForPendingReloadForTesting()
        #expect((moved as NSString).lastPathComponent != "Pane Title.md")
        #expect(store.isIndexedNote(path: moved))
        let workspaceTarget = CmuxNoteAttachmentTarget.workspace(workspaceAnchorId: "anchor-display")
        let movedRecord = try #require(try CmuxNoteStore.list(projectRoot: projectRoot).first { $0.slug == "pane-title" })
        #expect(movedRecord.attachments.contains { $0.matches(workspaceTarget) })
        #expect(!movedRecord.attachments.contains { $0.matches(target) })

        let node = try #require(store.rootNodes.first { $0.path == moved })
        #expect(node.displayName == "Pane Title")
    }

    /// A failed trash must not desynchronize the index: the body is still on
    /// disk, so the record has to survive for `cmux note list/read/open`.
    @Test @MainActor func failedTrashKeepsIndexRecords() throws {
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-trash"
        )
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-trash"
        )
        _ = try CmuxNoteStore.createOrOpen(
            slug: "sticky", projectRoot: projectRoot, createIfMissing: true
        )
        let folder = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "keep")
        let body = try CmuxNoteStore.relocateBody(
            slug: "sticky", projectRoot: projectRoot, toDirectory: folder
        )
        // Immutable parent makes trashItem fail deterministically.
        try fm.setAttributes([.immutable: true], ofItemAtPath: folder)
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: folder) }
        store.delete(path: body)
        try fm.setAttributes([.immutable: false], ofItemAtPath: folder)
        #expect(fm.fileExists(atPath: body))
        #expect(try CmuxNoteStore.list(projectRoot: projectRoot).contains { $0.slug == "sticky" })
    }

    /// Index-owned flat notes rename by retitling their record: the body file
    /// must stay put (its path is pinned by `index.json`) while the tree and
    /// `cmux note list` pick up the new title — regression for the tree
    /// offering no rename at all for notes created from panes.
    @Test @MainActor func renameFlatNoteRetitlesRecordWithoutMovingBody() throws {
        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-retitle"
        )
        _ = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-retitle"
        )
        let created = try CmuxNoteStore.createOrOpen(
            slug: "pane-note", title: "Untitled", projectRoot: projectRoot, createIfMissing: true
        )
        let body = created.path

        let renamed = store.renameFlatNote(path: body, toTitle: "  API design  ")
        #expect(renamed == (body as NSString).standardizingPath)
        let record = try #require(
            try CmuxNoteStore.list(projectRoot: projectRoot).first { $0.slug == "pane-note" }
        )
        #expect(record.title == "API design")  // whitespace-trimmed
        #expect(CmuxNoteStore.noteBodyPath(for: record, projectRoot: projectRoot) == body)
        #expect(fm.fileExists(atPath: body))

        // A whitespace-only title keeps the current one (parity with the FS
        // rename sanitizer rejecting empty file names).
        _ = store.renameFlatNote(path: body, toTitle: "   ")
        let unchanged = try #require(
            try CmuxNoteStore.list(projectRoot: projectRoot).first { $0.slug == "pane-note" }
        )
        #expect(unchanged.title == "API design")

        // Paths with no index record are not flat notes — nil, no writes.
        #expect(store.renameFlatNote(path: "/nonexistent/file.md", toTitle: "X") == nil)
    }

    @Test func retitleUnknownSlugThrowsNotFound() throws {
        #expect(throws: CmuxNoteStoreError.self) {
            _ = try CmuxNoteStore.retitle(slug: "ghost", projectRoot: projectRoot, title: "T")
        }
    }

    /// Every observed terminal becomes a virtual folder row. Pane-attached
    /// flat notes nest there immediately, while session records only appear
    /// there when the latest pane observation still sees that session live.
}
