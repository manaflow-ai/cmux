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

    @Test func listFlatNotesShowsOnlyRootLevelMarkdownFiles() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, cwd: "/work", title: "WS"
        )
        // The flat-note directory is the workspace folder's parent
        // (<projectRoot>/.cmux/notes), shared with `cmux note` output.
        let notesDir = (root as NSString).deletingLastPathComponent
        try write("flat note", to: (notesDir as NSString).appendingPathComponent("note-abc.md"))
        try write("{}", to: (notesDir as NSString).appendingPathComponent("index.json"))
        try write("hidden", to: (notesDir as NSString).appendingPathComponent(".hidden.md"))

        let flat = NotesTreeStorage.listFlatNotes(inNotesDir: notesDir)
        // Only the markdown file: no index.json, no dotfiles, and crucially no
        // workspace folders (this workspace's or any other's).
        #expect(flat.map(\.name) == ["note-abc.md"])
        #expect(flat.allSatisfy { $0.kind == .note })
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
}
