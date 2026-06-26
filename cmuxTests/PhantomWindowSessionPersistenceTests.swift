import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Phantom-window session integrity (issue #6646).
///
/// An unclean shutdown (e.g. a power outage) can leave the session file with
/// "phantom" windows — windows that carry no tabs/surfaces. Replaying those
/// empty shells on launch creates content-less windows that, on a multi-display
/// Mac, can wedge the WindowServer and freeze the desktop. The persistence layer
/// must discard them on load (an all-phantom session is unusable) so the app
/// opens a fresh window instead of replaying the phantoms.
@Suite("Phantom window session integrity (#6646)")
struct PhantomWindowSessionPersistenceTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(appSupportDirectory: URL) -> SessionSnapshotRepository<AppSessionSnapshot> {
        SessionSnapshotRepository(
            schemaVersion: SessionSnapshotSchema.currentVersion,
            bundleIdentifier: "com.cmuxterm.tests",
            appSupportDirectory: appSupportDirectory
        )
    }

    /// A "phantom" window: an empty shell with no tabs/surfaces.
    private func makePhantomWindow() -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 0, y: 0, width: 800, height: 600),
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 220)
        )
    }

    /// A real window: one workspace (tab). Panels may be empty — a tab with no
    /// surfaces is still restorable (it can be a pinned/titled tab the user
    /// wants to keep), which is why the phantom test is "no tabs", not "no panels".
    private func makeRealWindow() -> SessionWindowSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Restored",
            customColor: nil,
            isPinned: true,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        return SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )
    }

    private func makeSnapshot(windows: [SessionWindowSnapshot]) -> AppSessionSnapshot {
        AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 0,
            windows: windows
        )
    }

    /// Writes a snapshot to disk exactly as it would be persisted, independent of
    /// the store's save-time policy, so the on-disk corruption state is faithful.
    private func writeSnapshotJSON(_ snapshot: AppSessionSnapshot, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    @Test("an all-phantom (0-tab) session is unusable so the app opens a fresh window")
    func allPhantomSessionIsUnusable() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(appSupportDirectory: dir)
        let fileURL = try #require(store.defaultSnapshotFileURL())
        // The reporter's file: 3 windows, every one with 0 tabs/surfaces.
        try writeSnapshotJSON(
            makeSnapshot(windows: [makePhantomWindow(), makePhantomWindow(), makePhantomWindow()]),
            to: fileURL
        )

        guard case .unusable = store.loadOutcome(fileURL: fileURL) else {
            Issue.record("A session of only phantom (0-tab) windows must be unusable (#6646)")
            return
        }
        #expect(store.load(fileURL: fileURL) == nil)
    }

    @Test("phantom windows are dropped on load but real windows are kept")
    func phantomWindowsDroppedRealWindowsKept() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(appSupportDirectory: dir)
        let fileURL = try #require(store.defaultSnapshotFileURL())
        try writeSnapshotJSON(
            makeSnapshot(windows: [makePhantomWindow(), makeRealWindow(), makePhantomWindow()]),
            to: fileURL
        )

        guard case .loaded(let restored) = store.loadOutcome(fileURL: fileURL) else {
            Issue.record("A session with at least one real window must stay loadable (#6646)")
            return
        }
        #expect(restored.windows.count == 1)
        #expect(!restored.windows.contains(where: { $0.tabManager.workspaces.isEmpty }))
    }

    @Test("discardingNonRestorableWindows prunes phantoms and preserves real windows")
    func discardingNonRestorableWindowsContract() throws {
        // All phantom -> nil (treated as unusable / empty state).
        #expect(
            makeSnapshot(windows: [makePhantomWindow(), makePhantomWindow()])
                .discardingNonRestorableWindows == nil
        )

        // Mixed -> only the real window survives.
        let prunedMixed = try #require(
            makeSnapshot(windows: [makePhantomWindow(), makeRealWindow()]).discardingNonRestorableWindows
        )
        #expect(prunedMixed.windows.count == 1)
        #expect(prunedMixed.windows.first?.tabManager.workspaces.count == 1)

        // All restorable -> unchanged.
        let prunedReal = try #require(
            makeSnapshot(windows: [makeRealWindow(), makeRealWindow()]).discardingNonRestorableWindows
        )
        #expect(prunedReal.windows.count == 2)
    }
}
