import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WindowGeometryHintTests: XCTestCase {
    func testResolvedWindowFramePrefersSavedDisplayIdentity() {
        let savedFrame = SessionRectSnapshot(x: 1_200, y: 100, width: 600, height: 400)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            frame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800)
        )

        let display1 = SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        let display2 = SessionDisplayGeometry(
            displayID: 2,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let restored = WindowGeometryResolver.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [display1, display2],
            fallbackDisplay: display1
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertTrue(display2.visibleFrame.intersects(restored))
        XCTAssertFalse(display1.visibleFrame.intersects(restored))
        XCTAssertEqual(restored.width, 600, accuracy: 0.001)
        XCTAssertEqual(restored.height, 400, accuracy: 0.001)
        XCTAssertEqual(restored.minX, 200, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 100, accuracy: 0.001)
    }

    func testResolvedWindowFrameKeepsIntersectingFrameWithoutDisplayMetadata() {
        let savedFrame = SessionRectSnapshot(x: 120, y: 80, width: 500, height: 350)
        let display = SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let restored = WindowGeometryResolver.resolvedWindowFrame(
            from: savedFrame,
            display: nil,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 120, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 80, accuracy: 0.001)
        XCTAssertEqual(restored.width, 500, accuracy: 0.001)
        XCTAssertEqual(restored.height, 350, accuracy: 0.001)
    }

    func testResolvedStartupPrimaryWindowFrameFallsBackToPersistedGeometryWhenPrimaryMissing() {
        let fallbackFrame = SessionRectSnapshot(x: 180, y: 140, width: 900, height: 640)
        let fallbackDisplay = SessionDisplaySnapshot(
            displayID: 1,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
        )
        let display = SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        )

        let restored = WindowGeometryResolver.resolvedStartupPrimaryWindowFrame(
            primarySnapshot: nil,
            fallbackFrame: fallbackFrame,
            fallbackDisplaySnapshot: fallbackDisplay,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertEqual(restored.minX, 180, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 140, accuracy: 0.001)
        XCTAssertEqual(restored.width, 900, accuracy: 0.001)
        XCTAssertEqual(restored.height, 640, accuracy: 0.001)
    }

    func testResolvedStartupPrimaryWindowFramePrefersPrimarySnapshotOverFallback() {
        let primarySnapshot = SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 220, y: 160, width: 980, height: 700),
            display: SessionDisplaySnapshot(
                displayID: 1,
                frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
                visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
            ),
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 220)
        )
        let fallbackFrame = SessionRectSnapshot(x: 40, y: 30, width: 700, height: 500)
        let fallbackDisplay = SessionDisplaySnapshot(
            displayID: 1,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
        )
        let display = SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        )

        let restored = WindowGeometryResolver.resolvedStartupPrimaryWindowFrame(
            primarySnapshot: primarySnapshot,
            fallbackFrame: fallbackFrame,
            fallbackDisplaySnapshot: fallbackDisplay,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertEqual(restored.minX, 220, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 160, accuracy: 0.001)
        XCTAssertEqual(restored.width, 980, accuracy: 0.001)
        XCTAssertEqual(restored.height, 700, accuracy: 0.001)
    }

    func testFreshMainWindowFallbackWithoutSnapshotOrHintUsesVisibleFrameDefault() {
        let display = SessionDisplayGeometry(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 40, width: 1_600, height: 920)
        )

        let frame = WindowGeometryResolver.resolvedFreshMainWindowFrame(
            sharedGeometryHint: nil,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertTrue(display.visibleFrame.contains(frame))
        XCTAssertEqual(frame.width, display.visibleFrame.width * 0.8, accuracy: 0.001)
        XCTAssertEqual(frame.height, display.visibleFrame.height * 0.8, accuracy: 0.001)
    }

    func testFreshMainWindowFallbackUsesSharedGeometryHintWhenSnapshotIsMissing() {
        let hintFrame = SessionRectSnapshot(x: 220, y: 160, width: 980, height: 700)
        let hintDisplay = SessionDisplaySnapshot(
            displayID: 7,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: SessionRectSnapshot(x: 0, y: 40, width: 1_600, height: 920)
        )
        let hint = SharedWindowGeometryHint(
            version: SharedWindowGeometryHintStore.schemaVersion,
            updatedAt: 1_234,
            writerBundleIdentifier: "com.cmuxterm.app.debug.source",
            frame: hintFrame,
            display: hintDisplay
        )
        let display = SessionDisplayGeometry(
            displayID: 7,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 40, width: 1_600, height: 920)
        )

        let frame = WindowGeometryResolver.resolvedFreshMainWindowFrame(
            sharedGeometryHint: hint,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertEqual(frame.minX, 220, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 160, accuracy: 0.001)
        XCTAssertEqual(frame.width, 980, accuracy: 0.001)
        XCTAssertEqual(frame.height, 700, accuracy: 0.001)
    }

    func testFreshMainWindowFallbackIgnoresTinySharedGeometryHint() {
        let tinyHint = SharedWindowGeometryHint(
            version: SharedWindowGeometryHintStore.schemaVersion,
            updatedAt: 1_234,
            writerBundleIdentifier: "com.cmuxterm.app.debug.legacy",
            frame: SessionRectSnapshot(x: 470, y: 520, width: 460, height: 360),
            display: SessionDisplaySnapshot(
                displayID: 7,
                frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
                visibleFrame: SessionRectSnapshot(x: 0, y: 40, width: 1_600, height: 920)
            )
        )
        let display = SessionDisplayGeometry(
            displayID: 7,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 40, width: 1_600, height: 920)
        )

        let frame = WindowGeometryResolver.resolvedFreshMainWindowFrame(
            sharedGeometryHint: tinyHint,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertTrue(display.visibleFrame.contains(frame))
        XCTAssertEqual(frame.width, display.visibleFrame.width * 0.8, accuracy: 0.001)
        XCTAssertEqual(frame.height, display.visibleFrame.height * 0.8, accuracy: 0.001)
    }

    func testSavingSessionSnapshotAlsoWritesSharedWindowGeometryHint() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-window-hint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let hintURL = tempDir.appendingPathComponent("window-geometry-hint.json", isDirectory: false)
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)

        XCTAssertTrue(
            SessionPersistenceStore.save(
                snapshot,
                fileURL: snapshotURL,
                sharedWindowGeometryHintFileURL: hintURL,
                writerBundleIdentifier: "com.cmuxterm.app.debug.writer"
            )
        )

        let hint = try XCTUnwrap(SharedWindowGeometryHintStore.load(fileURL: hintURL))
        XCTAssertEqual(hint.version, SharedWindowGeometryHintStore.schemaVersion)
        XCTAssertEqual(hint.writerBundleIdentifier, "com.cmuxterm.app.debug.writer")
        XCTAssertEqual(hint.frame.x, 10, accuracy: 0.001)
        XCTAssertEqual(hint.frame.y, 20, accuracy: 0.001)
        XCTAssertEqual(hint.frame.width, 900, accuracy: 0.001)
        XCTAssertEqual(hint.frame.height, 700, accuracy: 0.001)
        XCTAssertEqual(hint.display?.displayID, 42)
    }

    func testCorruptMissingOrEmptySharedWindowGeometryHintFallsBackCleanly() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-window-hint-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hintURL = tempDir.appendingPathComponent("window-geometry-hint.json", isDirectory: false)
        let display = SessionDisplayGeometry(
            displayID: 3,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1_440, height: 875)
        )

        XCTAssertNil(SharedWindowGeometryHintStore.load(fileURL: hintURL))

        try Data().write(to: hintURL, options: .atomic)
        XCTAssertNil(SharedWindowGeometryHintStore.load(fileURL: hintURL))

        try Data("{\"not\":\"a hint\"}".utf8).write(to: hintURL, options: .atomic)
        XCTAssertNil(SharedWindowGeometryHintStore.load(fileURL: hintURL))

        let frame = WindowGeometryResolver.resolvedFreshMainWindowFrame(
            sharedGeometryHint: SharedWindowGeometryHintStore.load(fileURL: hintURL),
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertTrue(display.visibleFrame.contains(frame))
        XCTAssertEqual(frame.width, display.visibleFrame.width * 0.8, accuracy: 0.001)
        XCTAssertEqual(frame.height, display.visibleFrame.height * 0.8, accuracy: 0.001)
    }

    private func makeSnapshot(version: Int) -> AppSessionSnapshot {
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

        let tabManager = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [workspace]
        )

        let window = SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
            display: SessionDisplaySnapshot(
                displayID: 42,
                frame: SessionRectSnapshot(x: 0, y: 0, width: 1920, height: 1200),
                visibleFrame: SessionRectSnapshot(x: 0, y: 25, width: 1920, height: 1175)
            ),
            tabManager: tabManager,
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )

        return AppSessionSnapshot(
            version: version,
            createdAt: Date().timeIntervalSince1970,
            windows: [window]
        )
    }
}
