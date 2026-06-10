import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral tests for the Notes tree on-disk layer. Each test runs against a
/// fresh temp directory acting as a project root; no app launch required.
@Suite struct NotesTreeStorageTests {
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

        // A session folder is a directory carrying a _session.json marker.
        NotesTreeStorage.syncSessionFolders(
            inRoot: root,
            descriptors: [NotesSessionDescriptor(agent: "claude", sessionId: "s-1", title: "Auth Work", cwd: "/work", modified: 1_700_000_000)]
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

    @Test func sessionEntryBoundaryRejectsShellMetacharacterIds() throws {
        // Markers and the session-drag pasteboard are attacker-influenceable,
        // and resume commands splice the session id into shell input.
        let bad = NotesSessionMarker(
            agent: "claude", sessionId: "abc; rm -rf ~", cwd: "/work", title: "x", modified: 1
        )
        #expect(bad.makeSessionEntry() == nil)
        let good = NotesSessionMarker(
            agent: "claude",
            sessionId: "0f3c2a1b-1234-4cde-9f00-aa11bb22cc33",
            cwd: "/work",
            title: "x",
            modified: 1
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

    @Test func syncSessionFoldersIsIdempotentAndNeverDeletes() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        let descriptors = [
            NotesSessionDescriptor(agent: "claude", sessionId: "s-keep", title: "Keep", cwd: "/work", modified: 1_700_000_000)
        ]
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: descriptors)
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: descriptors)

        func sessionFolders(withId id: String) -> [String] {
            (try? fm.contentsOfDirectory(atPath: root))?.compactMap { name -> String? in
                let dir = (root as NSString).appendingPathComponent(name)
                guard let marker = NotesTreeStorage.sessionMarker(inDirectory: dir), marker.sessionId == id else {
                    return nil
                }
                return dir
            } ?? []
        }
        // Idempotent: re-running does not create a duplicate folder.
        #expect(sessionFolders(withId: "s-keep").count == 1)

        // A note filed under the session survives a later sync that no longer
        // lists that session (ended sessions are never deleted).
        let folder = try #require(sessionFolders(withId: "s-keep").first)
        try write("notes", to: (folder as NSString).appendingPathComponent("plan.md"))
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: [])
        #expect(fm.fileExists(atPath: (folder as NSString).appendingPathComponent("plan.md")))
        #expect(fm.fileExists(atPath: (folder as NSString).appendingPathComponent(NotesTreeStorage.sessionMarkerName)))
    }

    /// An open markdown panel must follow a Notes-tree relocation (exact file
    /// move, or a folder move above it) instead of flipping to
    /// "File unavailable" — regression for moved notes orphaning open viewers.
    @Test @MainActor func openMarkdownPanelsFollowNoteRelocations() async throws {
        let notesDir = (projectRoot as NSString).appendingPathComponent(".cmux/notes")
        let destDir = (notesDir as NSString).appendingPathComponent("dest")
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let oldPath = (notesDir as NSString).appendingPathComponent("a.md")
        try write("hello body", to: oldPath)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: oldPath)
        defer { panel.close() }
        #expect(panel.content == "hello body")

        // Mirror NotesTreeStore.move: relocate on disk, then announce it.
        let newPath = (destDir as NSString).appendingPathComponent("a.md")
        try fm.moveItem(atPath: oldPath, toPath: newPath)
        func postRelocation(from old: String, to new: String) {
            NotificationCenter.default.post(
                name: .cmuxNoteFileRelocated,
                object: nil,
                userInfo: [
                    "oldPath": (old as NSString).standardizingPath,
                    "newPath": (new as NSString).standardizingPath,
                ]
            )
        }
        postRelocation(from: oldPath, to: newPath)
        let expected = (newPath as NSString).standardizingPath
        for _ in 0..<200 where panel.filePath != expected {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(panel.filePath == expected)
        #expect(!panel.isFileUnavailable)
        #expect(panel.content == "hello body")

        // Folder rename above the file: the panel's path remaps by prefix.
        let renamedDir = (notesDir as NSString).appendingPathComponent("dest2")
        try fm.moveItem(atPath: destDir, toPath: renamedDir)
        postRelocation(from: destDir, to: renamedDir)
        let remapped = ((renamedDir as NSString).appendingPathComponent("a.md") as NSString).standardizingPath
        for _ in 0..<200 where panel.filePath != remapped {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(panel.filePath == remapped)
        #expect(!panel.isFileUnavailable)
    }
}
