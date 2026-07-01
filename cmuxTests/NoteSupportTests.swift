import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - XCTest-style assertion shims over Swift Testing
// Pattern: cmuxTests/TerminalControllerSocketSecurityTests.swift.

private func testComment(_ message: @autoclosure () -> String) -> Comment? {
    let value = message()
    return value.isEmpty ? nil : Comment(rawValue: value)
}

private func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 == value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 != value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression(), testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value = try expression()
        #expect(!value, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression() == nil, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        _ = try expression()
        Issue.record(
            testComment(message()) ?? "Expected expression to throw an error",
            sourceLocation: sourceLocation
        )
    } catch {
        // Expected: the expression threw.
    }
}

// MARK: - Note support

@MainActor
@Suite(.serialized)
struct NoteSupportTests {

    @Test func testNoteSlugFromPathRejectsInvalidFilenames() {
        XCTAssertNil(NoteSupport.slug(forNotePath: "/tmp/project/.cmux/notes/Bad Name.md"))
        XCTAssertNil(NoteSupport.slug(forNotePath: "/tmp/project/.cmux/notes/-todo.md"))
        XCTAssertEqual(
            NoteSupport.slug(forNotePath: "/tmp/project/.cmux/notes/todo-1.md"),
            "todo-1"
        )
    }

    @Test func testProjectRootFromNotePathIsPurePathDecomposition() {
        XCTAssertEqual(
            NoteSupport.projectRoot(forNotePath: "/tmp/project/.cmux/notes/todo-1.md"),
            "/tmp/project"
        )
        XCTAssertNil(NoteSupport.projectRoot(forNotePath: "/tmp/project/notes/todo-1.md"))
    }

    @Test func testRestoredProjectRootPrefersCurrentDirectoryWhenStoredNoteMoved() {
        XCTAssertEqual(
            NoteSupport.restoredProjectRoot(
                forStoredNotePath: "/tmp/old-project/.cmux/notes/todo-1.md",
                currentDirectory: "/tmp/new-project"
            ),
            "/tmp/new-project"
        )
        XCTAssertEqual(
            NoteSupport.restoredProjectRoot(
                forStoredNotePath: "/tmp/project/.cmux/notes/todo-1.md",
                currentDirectory: "/tmp/project/subdir"
            ),
            "/tmp/project"
        )
    }

    @Test func testConfigFallbackSlugIsDeterministicAndValid() throws {
        let first = NoteSupport.configFallbackSlug(seed: "root.0.surface.1")
        let second = NoteSupport.configFallbackSlug(seed: "root.0.surface.1")
        let other = NoteSupport.configFallbackSlug(seed: "root.1.surface.1")

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(try NoteSupport.validateSlug(first), first)
    }

    @Test func testDeleteNoteIsIdempotentWhenFileIsAlreadyAbsent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(try NoteSupport.deleteNote(slug: "todo", projectRoot: root.path))
    }

    @Test func testIndexedNoteCreateAttachesAndReusesCurrentSurfaceNote() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = CmuxNoteAttachmentTarget.surface(
            workspaceAnchorId: "workspace-anchor",
            surfaceAnchorId: "surface-anchor",
            surfaceKind: PanelType.terminal.rawValue
        )
        let created = try CmuxNoteStore.createOrOpen(
            slug: nil,
            title: "Build Notes",
            projectRoot: root.path,
            createIfMissing: true,
            attachment: target,
            preferAttachedExisting: true
        )

        XCTAssertTrue(created.created)
        XCTAssertTrue(created.attached)
        XCTAssertEqual(created.note.title, "Build Notes")
        XCTAssertEqual(created.note.attachments.count, 1)
        XCTAssertEqual(created.note.attachments.first?.workspaceAnchorId, "workspace-anchor")
        XCTAssertEqual(created.note.attachments.first?.surfaceAnchorId, "surface-anchor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: CmuxNoteStore.indexPath(forProjectRoot: root.path)))

        let reopened = try CmuxNoteStore.createOrOpen(
            slug: nil,
            projectRoot: root.path,
            createIfMissing: true,
            attachment: target,
            preferAttachedExisting: true
        )

        XCTAssertFalse(reopened.created)
        XCTAssertFalse(reopened.attached)
        XCTAssertEqual(reopened.note.id, created.note.id)
        XCTAssertEqual(reopened.path, created.path)
    }

    @Test func testNoteContextResolverPrefersSurfaceThenWorkspace() {
        let workspaceTarget = CmuxNoteAttachmentTarget.workspace(workspaceAnchorId: "ws-1")
        let surfaceTarget = CmuxNoteAttachmentTarget.surface(
            workspaceAnchorId: "ws-1",
            surfaceAnchorId: "surf-1",
            surfaceKind: "terminal"
        )

        func note(_ slug: String, updatedAt: TimeInterval, attachments: [CmuxNoteAttachment]) -> CmuxNoteRecord {
            CmuxNoteRecord(
                id: slug,
                slug: slug,
                title: slug,
                bodyPath: "notes/\(slug).md",
                attachments: attachments,
                createdAt: 0,
                updatedAt: updatedAt
            )
        }

        let surfaceOld = note("surf-old", updatedAt: 10, attachments: [surfaceTarget.attachment])
        let surfaceNew = note("surf-new", updatedAt: 20, attachments: [surfaceTarget.attachment])
        let workspaceNote = note("ws-note", updatedAt: 30, attachments: [workspaceTarget.attachment])
        let unlinked = note("free", updatedAt: 40, attachments: [])

        let resolution = CmuxNoteContextResolver.resolve(
            notes: [unlinked, workspaceNote, surfaceOld, surfaceNew],
            surfaceTarget: surfaceTarget,
            workspaceTarget: workspaceTarget
        )

        // A surface-linked note wins over a workspace-linked one even though the
        // workspace note (and an unlinked note) are more recently updated.
        XCTAssertEqual(resolution.resolvedNoteId, "surf-new")
        XCTAssertEqual(resolution.link(for: surfaceNew), .surface)
        XCTAssertEqual(resolution.link(for: surfaceOld), .surface)
        XCTAssertEqual(resolution.link(for: workspaceNote), .workspace)
        XCTAssertNil(resolution.link(for: unlinked))
        // Order: surface-linked (newest first), then workspace, then unlinked.
        XCTAssertEqual(resolution.orderedNotes.map(\.slug), ["surf-new", "surf-old", "ws-note", "free"])
    }

    @Test func testNoteContextResolverFallsBackToWorkspaceThenNil() {
        let workspaceTarget = CmuxNoteAttachmentTarget.workspace(workspaceAnchorId: "ws-1")
        let surfaceTarget = CmuxNoteAttachmentTarget.surface(
            workspaceAnchorId: "ws-1",
            surfaceAnchorId: "surf-x",
            surfaceKind: "terminal"
        )

        func note(_ slug: String, attachments: [CmuxNoteAttachment]) -> CmuxNoteRecord {
            CmuxNoteRecord(
                id: slug,
                slug: slug,
                title: slug,
                bodyPath: "notes/\(slug).md",
                attachments: attachments,
                createdAt: 0,
                updatedAt: 0
            )
        }

        // No surface-linked note for this caller's surface → workspace note resolves.
        let workspaceNote = note("ws", attachments: [workspaceTarget.attachment])
        let workspaceResolution = CmuxNoteContextResolver.resolve(
            notes: [workspaceNote],
            surfaceTarget: surfaceTarget,
            workspaceTarget: workspaceTarget
        )
        XCTAssertEqual(workspaceResolution.resolvedNoteId, "ws")

        // No links at all → nothing resolves.
        let unlinked = note("free", attachments: [])
        let emptyResolution = CmuxNoteContextResolver.resolve(
            notes: [unlinked],
            surfaceTarget: surfaceTarget,
            workspaceTarget: workspaceTarget
        )
        XCTAssertNil(emptyResolution.resolvedNoteId)
        XCTAssertNil(emptyResolution.link(for: unlinked))
    }

    @Test func testIndexedNoteAsyncCreateUsesSerializedStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let created = try await CmuxNoteStore.createOrOpenAsync(
            slug: "async-note",
            title: "Async Note",
            projectRoot: root.path,
            createIfMissing: true
        )
        let reopened = try CmuxNoteStore.createOrOpen(
            slug: "async-note",
            projectRoot: root.path,
            createIfMissing: false
        )

        XCTAssertTrue(created.created)
        XCTAssertEqual(created.note.id, reopened.note.id)
        XCTAssertEqual(created.path, reopened.path)
    }

    @Test func testIndexedNoteStoreKeepsLegacySlugFilesAddressable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyPath = try NoteSupport.ensureNoteFile(slug: "todo", projectRoot: root.path)
        try "# Todo\n".write(toFile: legacyPath, atomically: true, encoding: .utf8)

        let opened = try CmuxNoteStore.createOrOpen(
            slug: "todo",
            projectRoot: root.path,
            createIfMissing: false
        )

        XCTAssertFalse(opened.created)
        XCTAssertEqual(opened.note.id, "legacy-todo")
        XCTAssertEqual(opened.note.bodyPath, "notes/todo.md")
        XCTAssertEqual(opened.path, legacyPath)
        XCTAssertEqual(try CmuxNoteStore.path(slug: "todo", projectRoot: root.path).path, legacyPath)
    }

    @Test func testIndexedNoteStoreReadsWritesAndAppendsContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let written = try CmuxNoteStore.write(
            slug: "agent-notes",
            title: "Agent Notes",
            content: "alpha",
            projectRoot: root.path
        )
        XCTAssertEqual(written.note.slug, "agent-notes")
        XCTAssertEqual(written.note.title, "Agent Notes")
        XCTAssertEqual(try CmuxNoteStore.read(slug: "agent-notes", projectRoot: root.path).content, "alpha")

        let appended = try CmuxNoteStore.append(
            slug: "agent-notes",
            content: "\nbeta",
            projectRoot: root.path
        )
        XCTAssertEqual(appended.note.id, written.note.id)
        XCTAssertEqual(try CmuxNoteStore.read(slug: "agent-notes", projectRoot: root.path).content, "alpha\nbeta")

        XCTAssertThrowsError(
            try CmuxNoteStore.write(
                slug: "missing",
                content: "nope",
                projectRoot: root.path,
                createIfMissing: false
            )
        )
    }

    @Test func testIndexedNoteDeleteRestoresIndexWhenBodyCleanupCannotUnlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let created = try CmuxNoteStore.createOrOpen(
            slug: "blocked-delete",
            projectRoot: root.path,
            createIfMissing: true
        )
        try FileManager.default.removeItem(atPath: created.path)
        try FileManager.default.createDirectory(atPath: created.path, withIntermediateDirectories: false)

        XCTAssertThrowsError(try CmuxNoteStore.delete(slug: "blocked-delete", projectRoot: root.path))
        let retained = try CmuxNoteStore.path(slug: "blocked-delete", projectRoot: root.path)
        XCTAssertEqual(retained.path, created.path)
        XCTAssertFalse(retained.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
    }
}
