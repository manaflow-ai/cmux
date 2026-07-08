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
    /// closed rather than attach notes to — or resume — the wrong one.
    @Test func anonymousAgentResolutionRequiresUnambiguousMatch() {
        let now = Date().timeIntervalSince1970
        let anon = NotesTreeAnonymousAgentObservation(
            agent: "claude", startedAt: now - 60,
            surfaceAnchorId: "anchor-1", terminalPanelId: "panel-1"
        )
        func session(_ id: String, modified: TimeInterval, cwd: String = "/work") -> NotesSessionDescriptor {
            NotesSessionDescriptor(agent: "claude", sessionId: id, title: id, cwd: cwd, modified: modified)
        }

        // Exactly one live candidate: binds, and carries the pane identity.
        let unique = NotesTreeAnonymousResolution.resolve(
            anonymous: [anon],
            liveSessions: [session("s-1", modified: now)],
            workspaceCwd: "/work"
        )
        #expect(unique == [NotesTreeObservedSession(
            agent: "claude", sessionId: "s-1",
            surfaceAnchorId: "anchor-1", terminalPanelId: "panel-1"
        )])

        // Two same-agent sessions active in the cwd: ambiguous, no binding.
        let ambiguous = NotesTreeAnonymousResolution.resolve(
            anonymous: [anon],
            liveSessions: [session("s-1", modified: now), session("s-2", modified: now - 10)],
            workspaceCwd: "/work"
        )
        #expect(ambiguous.isEmpty)

        // Sessions inactive since before the process started (beyond the
        // resume slack) or in another cwd are not candidates, so a single
        // genuinely-live session still binds next to them.
        let filtered = NotesTreeAnonymousResolution.resolve(
            anonymous: [anon],
            liveSessions: [
                session("s-live", modified: now),
                session("s-stale", modified: now - 3600),
                session("s-elsewhere", modified: now, cwd: "/other"),
            ],
            workspaceCwd: "/work"
        )
        #expect(filtered.map(\.sessionId) == ["s-live"])
    }

    /// The per-workspace folder name is predictable, so a repository can
    /// commit `.cmux/notes/<workspace-folder>` as a symlink; the tree must
    /// neither adopt it, create through it, nor read/write its marker.
    @Test func symlinkedWorkspaceFolderIsRejected() throws {
        let notesDir = (projectRoot as NSString).appendingPathComponent(".cmux/notes")
        try fm.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
        let outside = (projectRoot as NSString).appendingPathComponent("elsewhere-ws")
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let folderName = NotesTreeStorage.workspaceFolderName(cwd: "/work", anchorId: "anchor-evil2")
        let linked = (notesDir as NSString).appendingPathComponent(folderName)
        try fm.createSymbolicLink(atPath: linked, withDestinationPath: outside)

        #expect(throws: NotesTreeStorageError.self) {
            try NotesTreeStorage.ensureWorkspaceRoot(
                projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-evil2"
            )
        }
        #expect(NotesTreeStorage.readWorkspaceSessions(inRoot: linked).isEmpty)
        let wrote = NotesTreeStorage.updateWorkspaceSessions(
            inRoot: linked, observed: [], live: [], now: 1_700_000_000
        )
        #expect(!wrote)
        #expect((try? fm.contentsOfDirectory(atPath: outside))?.isEmpty == true)
    }

    /// A committed symlink AT `.cmux/notes` (or `.cmux`) re-roots the entire
    /// containment boundary; both the flat store and the tree must refuse to
    /// operate instead of trusting the link target as the notes root.
    @Test func symlinkedNotesDirectoryDisablesNoteStorage() throws {
        let outside = (projectRoot as NSString).appendingPathComponent("elsewhere")
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let cmuxDir = (projectRoot as NSString).appendingPathComponent(".cmux")
        try fm.createDirectory(atPath: cmuxDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: (cmuxDir as NSString).appendingPathComponent("notes"),
            withDestinationPath: outside
        )

        #expect(throws: CmuxNoteStoreError.self) {
            _ = try CmuxNoteStore.createOrOpen(
                slug: "escape", projectRoot: projectRoot, createIfMissing: true
            )
        }
        #expect(throws: CmuxNoteStoreError.self) {
            _ = try CmuxNoteStore.list(projectRoot: projectRoot)
        }
        #expect(throws: NotesTreeStorageError.self) {
            try NotesTreeStorage.ensureWorkspaceRoot(
                projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-evil"
            )
        }
        // Nothing was created through the link.
        #expect((try? fm.contentsOfDirectory(atPath: outside))?.isEmpty == true)
    }

    /// The index-path confinement fallback must never return a path whose
    /// final component is a committed symlink — that is the same link that
    /// caused the escape, and note read/write/append would follow it out.
    @Test func bodyPathFallbackNeverReturnsASymlink() throws {
        let notesDir = (projectRoot as NSString).appendingPathComponent(".cmux/notes")
        try fm.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
        let outside = (projectRoot as NSString).appendingPathComponent("victim.md")
        try write("secret", to: outside)
        let link = (notesDir as NSString).appendingPathComponent("link.md")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: outside)

        let resolved = CmuxNoteStore.absoluteBodyPath(bodyPath: "notes/link.md", projectRoot: projectRoot)
        let type = (try? fm.attributesOfItem(atPath: resolved))?[.type] as? FileAttributeType
        #expect(type != .typeSymbolicLink)
        #expect((resolved as NSString).standardizingPath != (link as NSString).standardizingPath)
        let notesRoot = ((notesDir as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        #expect(resolved.hasPrefix(notesRoot + "/"))
    }

    /// A project-controlled index must never alias a note body onto cmux
    /// metadata or non-markdown files: the note index, tree markers, hidden
    /// files, and non-`.md` paths all resolve to a confined markdown leaf so
    /// note read/write/append/rm cannot corrupt or delete metadata.
    @Test func bodyPathNeverResolvesToNotesMetadata() throws {
        let notesDir = (projectRoot as NSString).appendingPathComponent(".cmux/notes")
        try fm.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
        let notesRoot = ((notesDir as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        let metadataNames = ["index.json", "_workspace.json", "_session.json"]
        let hostile = [
            "notes/index.json", "notes/INDEX.json", "notes/_workspace.json",
            "notes/ws/_session.json", "notes/.hidden.md", "notes/plain.txt", "notes",
        ]
        for bodyPath in hostile {
            let resolved = CmuxNoteStore.absoluteBodyPath(bodyPath: bodyPath, projectRoot: projectRoot)
            let leaf = (resolved as NSString).lastPathComponent
            #expect(resolved.hasPrefix(notesRoot + "/"), "\(bodyPath) escaped confinement")
            #expect(leaf.lowercased().hasSuffix(".md"), "\(bodyPath) resolved to non-markdown \(leaf)")
            #expect(!leaf.hasPrefix("."), "\(bodyPath) resolved to hidden \(leaf)")
            #expect(!metadataNames.contains(leaf.lowercased()), "\(bodyPath) resolved onto metadata \(leaf)")
        }
    }

    /// Symlinked children are never listed: a project-controlled link under
    /// the notes root must not let the tree traverse, open, or watch paths
    /// outside it.
    @Test func listEntriesSkipsSymlinkedChildren() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-link"
        )
        let outside = (projectRoot as NSString).appendingPathComponent("outside")
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try write("secret", to: (outside as NSString).appendingPathComponent("leak.md"))
        try fm.createSymbolicLink(
            atPath: (root as NSString).appendingPathComponent("escape"),
            withDestinationPath: outside
        )
        try fm.createSymbolicLink(
            atPath: (root as NSString).appendingPathComponent("alias.md"),
            withDestinationPath: (outside as NSString).appendingPathComponent("leak.md")
        )
        try write("real", to: (root as NSString).appendingPathComponent("real.md"))

        let names = NotesTreeStorage.listEntries(inDirectory: root).map(\.name)
        #expect(names.contains("real.md"))
        #expect(!names.contains("escape"))
        #expect(!names.contains("alias.md"))
    }

    /// A case-only rename must stay in place instead of colliding with
    /// itself on the (default) case-insensitive filesystem and coming back
    /// numerically suffixed (`Todo-2.md`).
    @Test func caseOnlyRenameDoesNotSuffix() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS", anchorId: "anchor-case"
        )
        let note = try NotesTreeStorage.newNote(inFolder: root, preferredName: "todo")
        let renamed = try NotesTreeStorage.rename(sourcePath: note, toName: "Todo")
        #expect((renamed as NSString).lastPathComponent == "Todo.md")
        let folder = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "docs")
        let renamedFolder = try NotesTreeStorage.rename(sourcePath: folder, toName: "Docs")
        #expect((renamedFolder as NSString).lastPathComponent == "Docs")
    }

    /// Nested tree paths resolve the same project root as flat note paths —
    /// regression for restore deriving `<cwd>/.cmux/notes/<leaf>` when a
    /// relocated note's parent is no longer the notes directory itself.
    @Test func projectRootResolvesForNestedNotePaths() {
        #expect(NoteSupport.projectRoot(forNotePath: "/r/p/.cmux/notes/x.md") == "/r/p")
        #expect(
            NoteSupport.projectRoot(forNotePath: "/r/p/.cmux/notes/ws-ab12/folder/x.md") == "/r/p"
        )
        #expect(NoteSupport.projectRoot(forNotePath: "/r/p/docs/x.md") == nil)
        #expect(NoteSupport.projectRoot(forNotePath: "/.cmux/notes/x.md") == nil)
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

        // Hidden user content also exempts a stale session folder from the
        // prune — only marker-only folders are disposable.
        let dotDescriptors = [
            NotesSessionDescriptor(agent: "claude", sessionId: "s-dot", title: "Dot", cwd: "/work", modified: 1_700_000_100)
        ]
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: dotDescriptors)
        let dotFolder = try #require(sessionFolders(withId: "s-dot").first)
        try write("SECRET=1", to: (dotFolder as NSString).appendingPathComponent(".env"))
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: [])
        #expect(fm.fileExists(atPath: (dotFolder as NSString).appendingPathComponent(".env")))
    }

    @Test func syncSessionFoldersSeparatesSameSessionIdAcrossAgents() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        let descriptors = [
            NotesSessionDescriptor(agent: "claude", sessionId: "shared-id", title: "Shared", cwd: "/work", modified: 20),
            NotesSessionDescriptor(agent: "codex", sessionId: "shared-id", title: "Shared", cwd: "/work", modified: 10),
        ]
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: descriptors)
        NotesTreeStorage.syncSessionFolders(inRoot: root, descriptors: descriptors)

        let markers = (try fm.contentsOfDirectory(atPath: root)).compactMap { name -> NotesSessionMarker? in
            let dir = (root as NSString).appendingPathComponent(name)
            return NotesTreeStorage.sessionMarker(inDirectory: dir)
        }
        #expect(markers.count == 2)
        #expect(Set(markers.map(\.agent)) == ["claude", "codex"])
        #expect(Set(markers.map(\.sessionId)) == ["shared-id"])
    }

    @Test func markerReadsRejectSymlinks() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        let sessionDir = (root as NSString).appendingPathComponent("linked-marker")
        try fm.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let target = (projectRoot as NSString).appendingPathComponent("outside-marker.json")
        try write(
            #"{"agent":"claude","sessionId":"s-link","cwd":"/work","title":"Linked","modified":1}"#,
            to: target
        )
        try fm.createSymbolicLink(
            atPath: (sessionDir as NSString).appendingPathComponent(NotesTreeStorage.sessionMarkerName),
            withDestinationPath: target
        )
        #expect(NotesTreeStorage.sessionMarker(inDirectory: sessionDir) == nil)
        #expect(!NotesTreeStorage.listEntries(inDirectory: root).contains { entry in
            entry.kind.sessionMarker?.sessionId == "s-link"
        })
    }

    @Test func markerReadsRejectOversizedFiles() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        let markerPath = (root as NSString).appendingPathComponent(NotesTreeStorage.workspaceMarkerName)
        try String(repeating: "x", count: 256 * 1024 + 1)
            .write(toFile: markerPath, atomically: true, encoding: .utf8)
        #expect(NotesTreeStorage.readWorkspaceSessions(inRoot: root).isEmpty)

        let sessionDir = (root as NSString).appendingPathComponent("oversized-marker")
        try fm.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let sessionMarkerPath = (sessionDir as NSString).appendingPathComponent(NotesTreeStorage.sessionMarkerName)
        try String(repeating: "x", count: 256 * 1024 + 1)
            .write(toFile: sessionMarkerPath, atomically: true, encoding: .utf8)
        #expect(NotesTreeStorage.sessionMarker(inDirectory: sessionDir) == nil)
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
        panel.markAsProjectNote(slug: "a", bodyPath: "notes/a.md")
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
        // The persisted body path stays index-relative (`notes/...`, relative
        // to `.cmux`) so session restore resolves against the project root.
        #expect(panel.noteBodyPath == "notes/dest/a.md")

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
