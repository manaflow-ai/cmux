import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension NotesTreeStore {
    /// Awaits the store's in-flight reload, reaching the internal `reloadTask`
    /// via `@testable import` (the store keeps no production test hook).
    @MainActor
    func waitForPendingReloadForTesting() async {
        await reloadTask?.value
    }
}

/// Behavioral tests for the Notes tree on-disk layer. Each test runs against a
/// fresh temp directory acting as a project root; no app launch required.
@Suite(.serialized) struct NotesTreeStorageTests {
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

    @Test func ensureWorkspaceRootCreatesMarkerAndRebindsByCwd() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work/project", title: "My Workspace"
        )
        #expect(fm.fileExists(atPath: root))
        let markerPath = (root as NSString).appendingPathComponent(NotesTreeStorage.workspaceMarkerName)
        #expect(fm.fileExists(atPath: markerPath))

        // The folder rebinds by cwd even when the title later changes, so a
        // renamed/re-instanced workspace never orphans its notes into a second
        // folder (the bug cwd-keying fixes).
        let resolved = NotesTreeStorage.resolveWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work/project"
        )
        #expect(resolved == root)

        // A different cwd resolves to a different folder.
        let other = NotesTreeStorage.resolveWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work/other"
        )
        #expect(other != root)
    }

    @Test func listEntriesHidesMarkersAndClassifiesKinds() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        try write("# todo", to: (root as NSString).appendingPathComponent("todo.md"))
        try write("hidden", to: (root as NSString).appendingPathComponent(".secret"))
        try write("not a note", to: (root as NSString).appendingPathComponent("readme.txt"))
        try fm.createDirectory(atPath: (root as NSString).appendingPathComponent("research"), withIntermediateDirectories: true)

        // A user-filed session folder is a directory carrying a _session.json marker.
        _ = NotesTreeStorage.createSessionFolder(
            inFolder: root,
            descriptor: NotesSessionDescriptor(
                agent: "claude",
                sessionId: "s-1",
                title: "Auth Work",
                cwd: "/work",
                modified: 1_700_000_000
            )
        )

        let entries = NotesTreeStorage.listEntries(inDirectory: root)
        let names = Set(entries.map(\.name))
        #expect(names.contains("todo.md"))
        #expect(names.contains("research"))
        #expect(!names.contains(NotesTreeStorage.workspaceMarkerName))
        #expect(!names.contains(".secret"))
        #expect(!names.contains("readme.txt"))  // non-markdown files are hidden

        let todo = try #require(entries.first { $0.name == "todo.md" })
        #expect(todo.kind == .note)
        let research = try #require(entries.first { $0.name == "research" })
        #expect(research.kind == .folder)
        let session = try #require(entries.first { entry in
            if case .sessionFolder = entry.kind { return true } else { return false }
        })
        if case .sessionFolder(let marker) = session.kind {
            #expect(marker.sessionId == "s-1")
            #expect(marker.title == "Auth Work")
        }
    }

    @Test func listEntriesHidesEmptyAutoSessionFoldersButShowsContentfulLegacyOnes() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        let autoDescriptor = NotesSessionDescriptor(
            agent: "claude",
            sessionId: "auto-empty",
            title: "Auto empty",
            cwd: "/work",
            modified: 1_700_000_000
        )
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: [autoDescriptor])
        var entries = NotesTreeStorage.listEntries(inDirectory: root)
        #expect(!entries.contains { $0.kind.sessionMarker?.sessionId == "auto-empty" })

        let autoFolder = try #require((try? fm.contentsOfDirectory(atPath: root))?.compactMap { name -> String? in
            let dir = (root as NSString).appendingPathComponent(name)
            return NotesTreeStorage.sessionMarker(inDirectory: dir)?.sessionId == "auto-empty" ? dir : nil
        }.first)
        try write("kept", to: (autoFolder as NSString).appendingPathComponent("note.md"))
        entries = NotesTreeStorage.listEntries(inDirectory: root)
        #expect(entries.contains { $0.path == autoFolder })
        #expect(fm.fileExists(atPath: (autoFolder as NSString).appendingPathComponent("note.md")))

        let promotedDescriptor = NotesSessionDescriptor(
            agent: "claude",
            sessionId: "promoted-empty",
            title: "Promoted empty",
            cwd: "/work",
            modified: 1_700_000_002
        )
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: [promotedDescriptor])
        let promotedAutoFolder = try #require((try? fm.contentsOfDirectory(atPath: root))?.compactMap { name -> String? in
            let dir = (root as NSString).appendingPathComponent(name)
            return NotesTreeStorage.sessionMarker(inDirectory: dir)?.sessionId == "promoted-empty" ? dir : nil
        }.first)
        entries = NotesTreeStorage.listEntries(inDirectory: root)
        #expect(!entries.contains { $0.path == promotedAutoFolder })
        let promotedUserFolder = try #require(NotesTreeStorage.createSessionFolder(
            inFolder: root,
            descriptor: promotedDescriptor
        ))
        #expect(promotedUserFolder == promotedAutoFolder)
        entries = NotesTreeStorage.listEntries(inDirectory: root)
        #expect(entries.contains { $0.path == promotedUserFolder })
        #expect(NotesTreeStorage.sessionMarker(inDirectory: promotedUserFolder)?.userCreated == true)

        let userFolder = try #require(NotesTreeStorage.createSessionFolder(
            inFolder: root,
            descriptor: NotesSessionDescriptor(
                agent: "claude",
                sessionId: "user-empty",
                title: "User empty",
                cwd: "/work",
                modified: 1_700_000_001
            )
        ))
        entries = NotesTreeStorage.listEntries(inDirectory: root)
        #expect(entries.contains { $0.path == userFolder })
        #expect(NotesTreeStorage.sessionMarker(inDirectory: userFolder)?.userCreated == true)
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: [])
        entries = NotesTreeStorage.listEntries(inDirectory: root)
        #expect(entries.contains { $0.path == userFolder })
    }

    @Test func moveRelocatesFileAndIsCollisionSafe() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        let note = try NotesTreeStorage.newNote(inFolder: root, preferredName: "alpha")
        let sub = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "sub")

        let moved = try NotesTreeStorage.move(sourcePath: note, intoFolder: sub)
        #expect((moved as NSString).lastPathComponent == "alpha.md")
        #expect(fm.fileExists(atPath: moved))
        #expect(!fm.fileExists(atPath: note))

        // A second note named the same lands in root, then moving it into `sub`
        // collides with the first and gets a unique name.
        let note2 = try NotesTreeStorage.newNote(inFolder: root, preferredName: "alpha")
        let moved2 = try NotesTreeStorage.move(sourcePath: note2, intoFolder: sub)
        #expect((moved2 as NSString).lastPathComponent == "alpha-2.md")
        #expect(fm.fileExists(atPath: moved2))
    }

    /// A repo can commit a broken symlink at the predictable new-note name
    /// (`untitled.md -> outside`); `fileExists` follows links and reports it
    /// free, but creation must neither write through it (that would create
    /// the target outside `.cmux/notes`) nor land on it — the name counts as
    /// occupied and the note gets the next unique name.
    @Test func newNoteNeverCreatesThroughPlantedSymlink() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        let escapeTarget = (projectRoot as NSString).appendingPathComponent("escaped-note.md")
        let planted = (root as NSString).appendingPathComponent("untitled.md")
        try fm.createSymbolicLink(atPath: planted, withDestinationPath: escapeTarget)

        let note = try NotesTreeStorage.newNote(inFolder: root, preferredName: "untitled")

        #expect((note as NSString).lastPathComponent == "untitled-2.md")
        #expect(fm.fileExists(atPath: note))
        #expect(!fm.fileExists(atPath: escapeTarget), "creation must not follow the planted link")
        #expect(NotesTreeStorage.isSymlink(planted), "the planted link itself must be untouched")
    }

    @Test func renameKeepsNoteExtensionAndSanitizesName() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        let note = try NotesTreeStorage.newNote(inFolder: root, preferredName: "untitled")

        // Plain rename: keeps the .md extension even when the user omits it.
        let renamed = try NotesTreeStorage.rename(sourcePath: note, toName: "Meeting Notes")
        #expect((renamed as NSString).lastPathComponent == "Meeting Notes.md")
        #expect(fm.fileExists(atPath: renamed))
        #expect(!fm.fileExists(atPath: note))

        // Typing the extension explicitly doesn't double it.
        let renamed2 = try NotesTreeStorage.rename(sourcePath: renamed, toName: "Plan.md")
        #expect((renamed2 as NSString).lastPathComponent == "Plan.md")

        // Path separators are sanitized, never treated as directories.
        let renamed3 = try NotesTreeStorage.rename(sourcePath: renamed2, toName: "a/b")
        #expect((renamed3 as NSString).lastPathComponent == "a-b.md")
        #expect((renamed3 as NSString).deletingLastPathComponent == root)

        // Renaming to the current name is a no-op returning the same path.
        let same = try NotesTreeStorage.rename(sourcePath: renamed3, toName: "a-b")
        #expect(same == renamed3)

        // Collision with a sibling gets a unique suffix instead of clobbering.
        let other = try NotesTreeStorage.newNote(inFolder: root, preferredName: "kept")
        let collided = try NotesTreeStorage.rename(sourcePath: other, toName: "a-b")
        #expect((collided as NSString).lastPathComponent == "a-b-2.md")
        #expect(fm.fileExists(atPath: renamed3))

        // Unusable names are rejected and the file is untouched.
        #expect(throws: NotesTreeStorageError.self) {
            _ = try NotesTreeStorage.rename(sourcePath: collided, toName: "   ")
        }
        #expect(fm.fileExists(atPath: collided))

        // Folders rename without gaining an extension.
        let folder = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "drafts")
        let renamedFolder = try NotesTreeStorage.rename(sourcePath: folder, toName: "Research")
        #expect((renamedFolder as NSString).lastPathComponent == "Research")
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: renamedFolder, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test @MainActor func confinementResolvesSymlinksBeforeAuthorizing() throws {
        // A symlinked directory inside the tree must not let mutations escape
        // the notes root (.cmux/notes/<ws>/out -> external target).
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-link"
        )
        let external = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cmux-notes-escape-\(UUID().uuidString)")
        try fm.createDirectory(atPath: external, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: external) }
        let victim = (external as NSString).appendingPathComponent("victim.md")
        try write("keep me", to: victim)
        let link = (root as NSString).appendingPathComponent("out")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: external)

        #expect(!NotesTreeStorage.isWithin(child: link, orEqualTo: root))

        let store = NotesTreeStore()
        store.setWorkspace(
            title: "WS", projectRoot: projectRoot, currentDirectory: "/work", anchorId: "anchor-link"
        )
        // Deleting "through" the link is refused; the external file survives.
        store.delete(path: (link as NSString).appendingPathComponent("victim.md"))
        #expect(fm.fileExists(atPath: victim))
        // Renaming the linked dir (which would rename the external target's
        // visibility) is refused too.
        #expect(store.rename(path: link, toName: "renamed") == nil)
    }

    @Test func moveRejectsFolderIntoItsOwnDescendant() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        let parent = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "parent")
        let inner = try NotesTreeStorage.newFolder(inFolder: parent, preferredName: "inner")
        #expect(throws: NotesTreeStorageError.self) {
            _ = try NotesTreeStorage.move(sourcePath: parent, intoFolder: inner)
        }
        #expect(fm.fileExists(atPath: parent))  // unchanged
    }

    @Test func workspaceRootsAreKeyedByAnchorAndAdoptLegacyCwdFolders() throws {
        // A folder written before anchor keying existed (no anchorId).
        let legacy = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work/app", title: "Legacy"
        )
        // The first anchored workspace binding to that cwd adopts the legacy
        // folder (no orphaned notes)…
        let adopted = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work/app", title: "WS A", anchorId: "anchor-a"
        )
        #expect(adopted == legacy)
        // …and rebinding resolves by anchor from then on.
        #expect(NotesTreeStorage.resolveWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work/app", anchorId: "anchor-a"
        ) == legacy)
        // A second workspace on the SAME cwd gets its own folder — same-cwd
        // workspaces must never blend their notes/sessions together.
        let second = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work/app", title: "WS B", anchorId: "anchor-b"
        )
        #expect(second != legacy)
        #expect(NotesTreeStorage.resolveWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work/app", anchorId: "anchor-b"
        ) == second)
    }

    @Test func workspaceSessionRecordsAccrueHydrateAndStayScoped() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-w"
        )
        // Observing a pane session persists a record with its surface anchor.
        let observed = [
            NotesTreeObservedSession(agent: "claude", sessionId: "s-1", surfaceAnchorId: "anchor-s1")
        ]
        #expect(NotesTreeStorage.updateWorkspaceSessions(
            inRoot: root, observed: observed, live: [], now: 100
        ))
        var records = NotesTreeStorage.readWorkspaceSessions(inRoot: root)
        #expect(records.count == 1)
        #expect(records[0].sessionId == "s-1")
        #expect(records[0].surfaceAnchorId == "anchor-s1")
        #expect(records[0].lastSeen == 100)

        // A live scan hydrates title/recency for recorded sessions, and live
        // sessions never observed in this workspace are NOT added — that is
        // the workspace scoping (vs. every session sharing the directory).
        let live = [
            NotesSessionDescriptor(agent: "claude", sessionId: "s-1", title: "Fix auth", cwd: "/work", modified: 200),
            NotesSessionDescriptor(agent: "claude", sessionId: "s-foreign", title: "Other workspace", cwd: "/work", modified: 999),
        ]
        #expect(NotesTreeStorage.updateWorkspaceSessions(
            inRoot: root, observed: [], live: live, now: 150
        ))
        records = NotesTreeStorage.readWorkspaceSessions(inRoot: root)
        #expect(records.count == 1)
        #expect(records[0].title == "Fix auth")
        #expect(records[0].modified == 200)

        // Idempotent: same inputs again rewrite nothing.
        #expect(!NotesTreeStorage.updateWorkspaceSessions(
            inRoot: root, observed: [], live: live, now: 150
        ))

        // ensureWorkspaceRoot rewrites (e.g. a title change) preserve records.
        _ = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "Renamed", anchorId: "anchor-w"
        )
        #expect(NotesTreeStorage.readWorkspaceSessions(inRoot: root).count == 1)
    }

    @Test func indexedFlatNotesAreScopedToWorkspaceAnchor() throws {
        _ = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-a"
        )
        let notesDir = NoteSupport.notesDirectory(forProjectRoot: projectRoot)
        func record(
            id: String, title: String, workspaceAnchor: String, surfaceAnchor: String?
        ) -> CmuxNoteRecord {
            CmuxNoteRecord(
                id: id,
                slug: "slug-\(id)",
                title: title,
                bodyPath: "notes/\(id).md",
                attachments: [
                    CmuxNoteAttachment(
                        kind: surfaceAnchor == nil ? .workspace : .surface,
                        workspaceAnchorId: workspaceAnchor,
                        surfaceAnchorId: surfaceAnchor,
                        surfaceKind: surfaceAnchor == nil ? nil : "terminal",
                        createdAt: 1
                    )
                ],
                createdAt: 1,
                updatedAt: 2
            )
        }
        struct IndexFixture: Codable {
            var version = 1
            var notes: [CmuxNoteRecord]
        }
        let fixture = IndexFixture(notes: [
            record(id: "pane", title: "Pane note", workspaceAnchor: "anchor-a", surfaceAnchor: "anchor-s1"),
            record(id: "ws", title: "Workspace note", workspaceAnchor: "anchor-a", surfaceAnchor: nil),
            record(id: "other", title: "Other workspace", workspaceAnchor: "anchor-b", surfaceAnchor: nil),
            record(id: "gone", title: "Missing body", workspaceAnchor: "anchor-a", surfaceAnchor: nil),
        ])
        let data = try JSONEncoder().encode(fixture)
        try data.write(to: URL(fileURLWithPath: (notesDir as NSString).appendingPathComponent("index.json")))
        try write("pane body", to: (notesDir as NSString).appendingPathComponent("pane.md"))
        try write("ws body", to: (notesDir as NSString).appendingPathComponent("ws.md"))
        try write("other body", to: (notesDir as NSString).appendingPathComponent("other.md"))
        // No body for "gone".

        let refs = NotesTreeStorage.listIndexedNotes(projectRoot: projectRoot, workspaceAnchorId: "anchor-a")
        // Only anchor-a notes with a live body; the pane note carries its
        // surface anchor so the tree can nest it under that pane's session.
        #expect(Set(refs.map(\.title)) == ["Pane note", "Workspace note"])
        let pane = try #require(refs.first { $0.title == "Pane note" })
        #expect(pane.surfaceAnchorId == "anchor-s1")
        #expect(pane.path.hasSuffix("/notes/pane.md") || pane.path.hasSuffix("pane.md"))
    }
}
