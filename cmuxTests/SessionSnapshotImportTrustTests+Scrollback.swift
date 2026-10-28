import CMUXAgentLaunch
import CmuxControlSocket
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SessionSnapshotImportTrustTests {
    @Test("imported scrollback is bounded before replay")
    func importedScrollbackIsTruncated() throws {
        let original = String(repeating: "x", count: SessionPersistencePolicy.maxScrollbackCharactersPerTerminal + 10)
        let terminal = SessionTerminalPanelSnapshot(scrollback: original)

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            Self.snapshot(terminal: terminal),
            source: Self.fileImport
        )

        let scrollback = try #require(
            restored.windows.first?.tabManager.workspaces.first?.panels.first?.terminal?.scrollback
        )
        #expect(scrollback.count == SessionPersistencePolicy.maxScrollbackCharactersPerTerminal)
        #expect(report.truncatedScrollbackCount == 1)
    }

    @Test("imported scrollback is bounded by Unicode scalars, not just characters")
    func importedScrollbackOfCombiningMarksIsBoundedByScalars() throws {
        // One grapheme cluster: a base character followed by a run of
        // combining marks. It counts as a single Character, so a character
        // bound alone lets every scalar through to the control-string
        // stripper, which copies the scalars into an array.
        let marks = String(repeating: "\u{0301}", count: SessionPersistencePolicy.maxScrollbackCharactersPerTerminal * 4 + 10)
        let original = "e" + marks
        #expect(original.count == 1)
        let terminal = SessionTerminalPanelSnapshot(scrollback: original)

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            Self.snapshot(terminal: terminal),
            source: Self.fileImport
        )

        let scrollback = try #require(
            restored.windows.first?.tabManager.workspaces.first?.panels.first?.terminal?.scrollback
        )
        #expect(scrollback.unicodeScalars.count <= SessionPersistencePolicy.maxScrollbackCharactersPerTerminal * 4)
        #expect(report.truncatedScrollbackCount == 1)
    }

    @Test("scrollback emptied by stripping is not counted as truncated")
    func strippedEmptyScrollbackIsNotTruncated() throws {
        let terminal = SessionTerminalPanelSnapshot(scrollback: "\u{1b}]0;title\u{07}")

        let (_, report) = SessionSnapshotImportTrust.snapshotForRestore(
            Self.snapshot(terminal: terminal),
            source: Self.fileImport
        )

        #expect(report.sanitizedScrollbackCount == 1)
        #expect(report.truncatedScrollbackCount == 0)
    }

    @Test("scalar and character truncation preserve the original ANSI control-string boundary")
    func scalarTruncationKeepsANSIContext() {
        let visible = String(repeating: "y", count: SessionPersistencePolicy.maxScrollbackCharactersPerTerminal - 4)
        let text = "\u{1b}]0;" + String(repeating: "x", count: SessionPersistencePolicy.maxScrollbackScalarsPerTerminal + 10)
            + "\u{7}" + visible
        #expect(SessionPersistencePolicy.truncatedScrollback(text) == visible)
    }

}
