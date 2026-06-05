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

    @Test func ensureWorkspaceRootCreatesMarkerAndRebindsByAnchor() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, anchorId: "anchor-abc123def", title: "My Workspace", cwd: "/work"
        )
        #expect(fm.fileExists(atPath: root))
        let markerPath = (root as NSString).appendingPathComponent(NotesTreeStorage.workspaceMarkerName)
        #expect(fm.fileExists(atPath: markerPath))

        // The folder rebinds by anchorId even when the title later changes, so a
        // renamed workspace never orphans its notes into a second folder.
        let resolved = NotesTreeStorage.resolveWorkspaceRoot(
            projectRoot: projectRoot, anchorId: "anchor-abc123def", title: "Completely Different Title"
        )
        #expect(resolved == root)

        // A different anchor resolves to a different folder.
        let other = NotesTreeStorage.resolveWorkspaceRoot(
            projectRoot: projectRoot, anchorId: "anchor-zzz999", title: "My Workspace"
        )
        #expect(other != root)
    }

    @Test func listEntriesHidesMarkersAndClassifiesKinds() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, anchorId: "anchor-list", title: "WS", cwd: "/work"
        )
        try write("# todo", to: (root as NSString).appendingPathComponent("todo.md"))
        try write("hidden", to: (root as NSString).appendingPathComponent(".secret"))
        try write("not a note", to: (root as NSString).appendingPathComponent("readme.txt"))
        try fm.createDirectory(atPath: (root as NSString).appendingPathComponent("research"), withIntermediateDirectories: true)

        // A session folder is a directory carrying a _session.json marker.
        NotesTreeStorage.syncSessionFolders(
            inRoot: root,
            descriptors: [NotesSessionDescriptor(agent: "claude", sessionId: "s-1", title: "Auth Work", cwd: "/work")]
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
            projectRoot: projectRoot, anchorId: "anchor-move", title: "WS", cwd: "/work"
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

    @Test func moveRejectsFolderIntoItsOwnDescendant() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, anchorId: "anchor-reject", title: "WS", cwd: "/work"
        )
        let parent = try NotesTreeStorage.newFolder(inFolder: root, preferredName: "parent")
        let inner = try NotesTreeStorage.newFolder(inFolder: parent, preferredName: "inner")
        #expect(throws: NotesTreeStorageError.self) {
            _ = try NotesTreeStorage.move(sourcePath: parent, intoFolder: inner)
        }
        #expect(fm.fileExists(atPath: parent))  // unchanged
    }

    @Test func syncSessionFoldersIsIdempotentAndNeverDeletes() throws {
        let root = try NotesTreeStorage.ensureWorkspaceRoot(
            projectRoot: projectRoot, anchorId: "anchor-sync", title: "WS", cwd: "/work"
        )
        let descriptors = [
            NotesSessionDescriptor(agent: "claude", sessionId: "s-keep", title: "Keep", cwd: "/work")
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
