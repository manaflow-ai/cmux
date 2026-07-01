import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Extracted from cmuxTests/WorkspaceSplitStartupCommandTests.swift so this
// branch's new coverage lives in a Swift Testing suite while the original
// XCTest file stays identical to main.
@MainActor
@Suite(.serialized)
struct WorkspaceNewNoteSwiftTests {
    @Test func testNewNoteForWorkspaceCreatesDistinctNotesEachTime() async throws {
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        workspace.currentDirectory = projectRoot.path

        // `await` cannot run inside #require's autoclosure, so resolve first.
        let firstPanel = await workspace.openAttachedNoteForWorkspace(inPane: paneId, focus: false)
        let first = try #require(firstPanel)
        let secondPanel = await workspace.openAttachedNoteForWorkspace(inPane: paneId, focus: false)
        let second = try #require(secondPanel)

        // Each "New Note" invocation must create a brand-new note rather than
        // refocusing the workspace's existing note. Regression: after the first
        // note was dragged to another pane, a second "New Note" just refocused
        // the original instead of creating another note.
        #expect(first.id != second.id)
        #expect(first.filePath != second.filePath)
        #expect(first.noteSlug != second.noteSlug)
        #expect(first.noteSlug != nil)
        #expect(second.noteSlug != nil)

        let notePanels = workspace.panels.values.compactMap { $0 as? MarkdownPanel }
        #expect(notePanels.count == 2)
    }
}
