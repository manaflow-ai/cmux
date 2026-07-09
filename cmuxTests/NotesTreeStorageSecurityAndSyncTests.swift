import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized) struct NotesTreeStorageSecurityAndSyncTests {
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
