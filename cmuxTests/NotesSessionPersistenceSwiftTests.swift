import CMUXAgentLaunch
import CmuxCore
import CmuxFoundation
import CmuxWorkspaces
import Darwin
import Foundation
import Testing
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func testComment(_ message: @autoclosure () -> String) -> Comment? {
    let value = message()
    return value.isEmpty ? nil : Comment(rawValue: value)
}

private func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
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

private func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression() == nil, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    let value = try expression()
    return try #require(value, testComment(message()), sourceLocation: sourceLocation)
}

/// Notes-feature session persistence coverage.
///
/// These tests live in their own Swift Testing suite (instead of the large
/// `SessionPersistenceTests` XCTest file) per the repo policy that new non-UI
/// test coverage uses Swift Testing.
@Suite(.serialized)
struct NotesSessionPersistenceSwiftTests {
    /// Notes-branch variant of
    /// `SessionPersistenceTests.testWorkspaceSessionSnapshotRestoresMarkdownPanel`
    /// that additionally locks in `displayMode` persistence for markdown panels.
    /// Named distinctly so it does not collide with the original XCTest, which
    /// still runs main's assertions.
    @Test @MainActor
    func testWorkspaceSessionSnapshotRestoresMarkdownPanelTextDisplayMode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markdownURL = root.appendingPathComponent("note.md")
        try "# hello\n".write(to: markdownURL, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(
            workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: markdownURL.path,
                focus: true
            )
        )
        workspace.setCustomTitle("Docs")
        workspace.setPanelCustomTitle(panelId: panel.id, title: "Readme")
        panel.setDisplayMode(.text)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.markdownPanel(for: restoredPanelId))
        XCTAssertEqual(restoredPanel.filePath, markdownURL.path)
        XCTAssertEqual(restoredPanel.displayMode, .text)
        XCTAssertEqual(restored.customTitle, "Docs")
        XCTAssertEqual(restored.panelTitle(panelId: restoredPanelId), "Readme")
    }

    @Test @MainActor
    func testWorkspaceSessionSnapshotRestoresNoteSlugAgainstMovedCurrentDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-note-move-\(UUID().uuidString)", isDirectory: true)
        let oldRoot = root.appendingPathComponent("old-project", isDirectory: true)
        let newRoot = root.appendingPathComponent("new-project", isDirectory: true)
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace()
        workspace.currentDirectory = oldRoot.path
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let createdPanel = await workspace.newNoteSurface(
            inPane: paneId,
            slug: "todo",
            focus: true
        )
        let notePanel = try XCTUnwrap(createdPanel)
        let noteBodyPath = try XCTUnwrap(notePanel.noteBodyPath)
        let oldNotePath = CmuxNoteStore.absoluteBodyPath(bodyPath: noteBodyPath, projectRoot: oldRoot.path)
        let expectedRestoredPath = CmuxNoteStore.absoluteBodyPath(bodyPath: noteBodyPath, projectRoot: newRoot.path)
        XCTAssertEqual(notePanel.filePath, oldNotePath)
        let originalWorkspaceAnchorId = workspace.noteAnchorId
        let originalPanelAnchorId = workspace.noteAnchorId(forPanelId: notePanel.id)

        workspace.currentDirectory = newRoot.path
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let markdownSnapshot = try XCTUnwrap(snapshot.panels.compactMap(\.markdown).first)
        XCTAssertEqual(markdownSnapshot.noteSlug, "todo")
        XCTAssertEqual(markdownSnapshot.noteBodyPath, noteBodyPath)
        XCTAssertEqual(snapshot.noteAnchorId, originalWorkspaceAnchorId)
        XCTAssertEqual(snapshot.panels.first { $0.id == notePanel.id }?.noteAnchorId, originalPanelAnchorId)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.markdownPanel(for: restoredPanelId))
        XCTAssertEqual(restoredPanel.filePath, expectedRestoredPath)
        XCTAssertEqual(restored.noteAnchorId, originalWorkspaceAnchorId)
        XCTAssertEqual(restored.noteAnchorIdsByPanelId[restoredPanelId], originalPanelAnchorId)
    }

    @Test @MainActor
    func testWorkspaceSessionSnapshotDoesNotPromotePlainMarkdownNotePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-plain-note-path-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let notePath = try NoteSupport.ensureNoteFile(slug: "todo", projectRoot: projectRoot.path)

        let workspace = Workspace()
        workspace.currentDirectory = projectRoot.path
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        _ = try XCTUnwrap(
            workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: notePath,
                focus: true
            )
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let markdownSnapshot = try XCTUnwrap(snapshot.panels.compactMap(\.markdown).first)
        XCTAssertNil(markdownSnapshot.noteSlug)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.markdownPanel(for: restoredPanelId))
        XCTAssertEqual(restoredPanel.filePath, notePath)
    }
}
