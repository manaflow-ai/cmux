import Foundation
import Testing

// No app import needed: this guard asserts against the checked-in sources,
// so it fails red on any tree where the row glyph is present regardless of
// how the app target compiles.

/// Regression guard: sidebar workspace rows must NOT render the leading
/// task-status circle glyph (the empty/half-filled "pie" circles).
///
/// History this guards against repeating: the circles shipped with
/// workspaces-as-todos (#7216), were removed by the full revert (#7761,
/// commit 657248a17), and came back when the feature was restored (#7790,
/// commit 998e7fb23) — pre-existing persisted workspaces restored to the
/// visible/Auto state, so the circles reappeared on every old workspace row.
/// The status feature itself (context-menu Status submenu, command palette,
/// CLI, todo pane, checklist) stays; only the per-row circle is banned.
///
/// The sidebar row is a SwiftUI shape subtree under a lazy list, so there is
/// no NSView to walk for a mounted-hierarchy assertion; scanning the row's
/// rendering sources is the repo's established guard pattern for "this must
/// not silently return" (see the `#filePath` repo-root scans in
/// `GhosttyConfigTests` / `RemoteShellCWDRelayTests`).
struct SidebarWorkspaceRowStatusGlyphRemovalTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // cmuxTests
            .deletingLastPathComponent() // repo root
    }

    /// The files that render sidebar workspace rows. The glyph view itself
    /// legitimately survives for the todo pane header and the status
    /// popover's lane rows — the ban is on the row rendering path.
    private static let rowRenderingSources = [
        "Sources/ContentView.swift",
        "Sources/TabItemView+WorkspaceTodo.swift",
    ]

    /// Identifiers that only exist while a status circle is wired into the
    /// sidebar row: the glyph views, the row-anchored status popover, and the
    /// container state that drove it.
    private static let bannedRowTokens = [
        "SidebarWorkspaceTaskStatusGlyph",
        "SidebarStatusPieShape",
        "SidebarWorkspaceStatusPopover",
        "statusPopoverWorkspaceId",
        "isStatusPopoverPresented",
    ]

    private static func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test
    func workspaceRowSourcesRenderNoStatusCircleGlyph() throws {
        for relativePath in Self.rowRenderingSources {
            let source = try Self.sourceText(relativePath)
            for token in Self.bannedRowTokens {
                #expect(
                    !source.contains(token),
                    """
                    \(relativePath) references \(token). Sidebar workspace rows must not \
                    render the leading task-status circle glyph (removed by #7761, \
                    resurrected by the #7790 feature restore, removed again here). If a \
                    merge or feature restore reintroduced the glyph block on the row's \
                    title line, delete it: status stays reachable through the context \
                    menu, command palette, CLI, and the todo pane.
                    """
                )
            }
        }
    }

    /// The row files under `Sources/Sidebar/` (slots, snapshot refresh
    /// policy, hover reconcilers, …) must not grow a status-glyph reference
    /// either; they are all below the sidebar snapshot boundary.
    @Test
    func sidebarRowSupportSourcesRenderNoStatusCircleGlyph() throws {
        let sidebarDir = Self.repoRoot.appendingPathComponent("Sources/Sidebar")
        let files = try FileManager.default
            .contentsOfDirectory(at: sidebarDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty, "Sources/Sidebar contained no Swift files; guard scan is broken.")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.bannedRowTokens {
                #expect(
                    !source.contains(token),
                    "Sources/Sidebar/\(file.lastPathComponent) references \(token); sidebar rows must not render the status circle glyph."
                )
            }
        }
    }

    /// The row snapshot must not carry glyph-only observation fields. Dead
    /// per-row observation wiring is exactly the class of sidebar perf
    /// incident tracked by #2586/#8004 — if status state beyond the done-dim
    /// `taskStatus` reappears in the snapshot, something is rendering status
    /// on rows again.
    @Test
    func workspaceSnapshotCarriesNoGlyphFeedingFields() throws {
        let source = try Self.sourceText("Sources/SidebarWorkspaceSnapshotBuilder.swift")
        for field in ["taskStatusHasOverride", "taskStatusInferred"] {
            #expect(
                !source.contains(field),
                "SidebarWorkspaceSnapshotBuilder.Snapshot regained \(field), a status-glyph-only field; sidebar rows must not observe status-glyph state."
            )
        }
    }
}
