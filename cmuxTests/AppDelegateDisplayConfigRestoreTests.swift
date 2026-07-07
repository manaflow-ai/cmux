import AppKit
import CmuxWindowing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Round-trip coverage for per-monitor window-geometry memory (issue #2135):
/// place a window on an external monitor, disconnect (window is remembered under
/// the built-in-only signature's *counterpart* — i.e. the disconnect must NOT
/// mutate the external slot), reconnect, and the remembered external frame is
/// restored. Everything here exercises the pure signature + resolvedWindowFrame
/// path, so it runs with no live displays.
final class AppDelegateDisplayConfigRestoreTests: XCTestCase {
    // MARK: fixtures

    private let builtInFrame = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    private let builtInVisible = CGRect(x: 0, y: 0, width: 1_512, height: 944)
    // External monitor placed to the left of the built-in.
    private let externalFrame = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
    private let externalVisible = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_055)

    private func geometry(
        _ stableID: String,
        _ frame: CGRect,
        _ visible: CGRect,
        displayID: UInt32
    ) -> AppDelegate.SessionDisplayGeometry {
        AppDelegate.SessionDisplayGeometry(
            displayID: displayID,
            stableID: stableID,
            frame: frame,
            visibleFrame: visible
        )
    }

    private var builtIn: AppDelegate.SessionDisplayGeometry {
        geometry("uuid:BUILTIN", builtInFrame, builtInVisible, displayID: 1)
    }

    private var external: AppDelegate.SessionDisplayGeometry {
        geometry("uuid:EXTERNAL", externalFrame, externalVisible, displayID: 2)
    }

    private func emptyWindowSnapshot(
        windowId: UUID? = nil,
        frame: SessionRectSnapshot? = nil,
        display: SessionDisplaySnapshot? = nil,
        configFrames: [SessionConfigFrameEntry]? = nil
    ) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            windowId: windowId,
            frame: frame,
            display: display,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil),
            configFrames: configFrames
        )
    }

    @MainActor
    private func closeCreatedWindow(_ appDelegate: AppDelegate, windowId: UUID) {
        guard let window = appDelegate.mainWindow(for: windowId) else { return }
#if DEBUG
        let previousConfirmationHandler = appDelegate.debugCloseMainWindowConfirmationHandler
        appDelegate.debugCloseMainWindowConfirmationHandler = { _ in true }
        defer { appDelegate.debugCloseMainWindowConfirmationHandler = previousConfirmationHandler }
#endif
        window.animationBehavior = .none
        window.orderOut(nil)
        window.close()
    }

    // MARK: the headline round-trip

    func testWindowFrameIsRestoredToExternalMonitorAfterReconnect() throws {
        // 1. Docked: built-in + external. User's window lives on the external.
        let dockedSignature = try XCTUnwrap(
            [builtIn, external].displayConfigurationSignature()
        )
        let externalWindowFrame = CGRect(x: -1_600, y: 200, width: 1_000, height: 700)

        // Remember that frame under the docked signature.
        var ring = SessionConfigFramePolicy.merged(
            [],
            upserting: SessionConfigFrameEntry(
                signature: dockedSignature,
                frame: SessionRectSnapshot(externalWindowFrame),
                display: SessionDisplaySnapshot(
                    displayID: 2,
                    stableID: "uuid:EXTERNAL",
                    frame: SessionRectSnapshot(externalFrame),
                    visibleFrame: SessionRectSnapshot(externalVisible)
                ),
                lastUsedAt: 100
            )
        )

        // 2. Disconnect: only the built-in remains. A capture at this point is
        //    keyed to the LAPTOP-ONLY signature, which differs from the docked
        //    one — so it must NOT overwrite the external slot (anti-#2135).
        let laptopSignature = try XCTUnwrap(
            [builtIn].displayConfigurationSignature()
        )
        XCTAssertNotEqual(dockedSignature, laptopSignature)
        // Simulate the built-in capture landing in its own slot.
        ring = SessionConfigFramePolicy.merged(
            ring,
            upserting: SessionConfigFrameEntry(
                signature: laptopSignature,
                frame: SessionRectSnapshot(CGRect(x: 256, y: 122, width: 1_000, height: 700)),
                display: SessionDisplaySnapshot(
                    displayID: 1,
                    stableID: "uuid:BUILTIN",
                    frame: SessionRectSnapshot(builtInFrame),
                    visibleFrame: SessionRectSnapshot(builtInVisible)
                ),
                lastUsedAt: 200
            )
        )

        // The external slot is intact and unchanged (the disconnect did not
        // corrupt it — this is the exact #2135 failure being guarded).
        let externalEntry = try XCTUnwrap(
            SessionConfigFramePolicy.entry(for: dockedSignature, in: ring)
        )
        XCTAssertEqual(externalEntry.frame.cgRect, externalWindowFrame)

        // 3. Reconnect: signature returns to docked. Restore resolves the
        //    remembered external frame back onto the external monitor.
        let restored = AppDelegate.resolvedWindowFrame(
            from: externalEntry.frame,
            display: externalEntry.display,
            availableDisplays: [builtIn, external],
            fallbackDisplay: builtIn
        )
        let resolved = try XCTUnwrap(restored)
        XCTAssertEqual(resolved, externalWindowFrame, "remembered external frame should round-trip exactly")
        XCTAssertTrue(externalVisible.intersects(resolved), "restored frame lands on the external monitor")
    }

    func testStableDisplayIdentityWinsWhenDisplayIDIsReassigned() throws {
        let savedFrame = CGRect(x: -1_600, y: 200, width: 1_000, height: 700)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            stableID: "uuid:EXTERNAL",
            frame: SessionRectSnapshot(externalFrame),
            visibleFrame: SessionRectSnapshot(externalVisible)
        )
        let builtInWithOldExternalID = geometry(
            "uuid:BUILTIN",
            builtInFrame,
            builtInVisible,
            displayID: 2
        )
        let externalWithNewID = geometry(
            "uuid:EXTERNAL",
            externalFrame,
            externalVisible,
            displayID: 9
        )

        let restored = try XCTUnwrap(
            AppDelegate.resolvedWindowFrame(
                from: SessionRectSnapshot(savedFrame),
                display: savedDisplay,
                availableDisplays: [builtInWithOldExternalID, externalWithNewID],
                fallbackDisplay: builtInWithOldExternalID
            )
        )

        XCTAssertEqual(restored, savedFrame)
        XCTAssertTrue(externalVisible.intersects(restored))
        XCTAssertFalse(builtInVisible.intersects(restored))
    }

    func testRestorePrefersCurrentConfigurationFrameEntry() throws {
        let dockedSignature = try XCTUnwrap([builtIn, external].displayConfigurationSignature())
        let laptopFrame = CGRect(x: 256, y: 122, width: 900, height: 600)
        let externalFrameForDock = CGRect(x: -1_600, y: 200, width: 1_000, height: 700)
        let snapshot = emptyWindowSnapshot(
            frame: SessionRectSnapshot(laptopFrame),
            display: SessionDisplaySnapshot(
                displayID: 1,
                stableID: "uuid:BUILTIN",
                frame: SessionRectSnapshot(builtInFrame),
                visibleFrame: SessionRectSnapshot(builtInVisible)
            ),
            configFrames: [
                SessionConfigFrameEntry(
                    signature: dockedSignature,
                    frame: SessionRectSnapshot(externalFrameForDock),
                    display: SessionDisplaySnapshot(
                        displayID: 2,
                        stableID: "uuid:EXTERNAL",
                        frame: SessionRectSnapshot(externalFrame),
                        visibleFrame: SessionRectSnapshot(externalVisible)
                    ),
                    lastUsedAt: 200
                )
            ]
        )

        let restored = try XCTUnwrap(
            AppDelegate.resolvedWindowFrame(
                from: snapshot,
                currentSignature: dockedSignature,
                availableDisplays: [builtIn, external],
                fallbackDisplay: builtIn
            )
        )
        let startup = try XCTUnwrap(
            AppDelegate.resolvedStartupPrimaryWindowFrame(
                primarySnapshot: snapshot,
                fallbackFrame: nil,
                fallbackDisplaySnapshot: nil,
                availableDisplays: [builtIn, external],
                fallbackDisplay: builtIn
            )
        )

        XCTAssertEqual(restored, externalFrameForDock)
        XCTAssertEqual(startup, externalFrameForDock)
    }

    @MainActor
    func testSnapshotBackedWindowCreationSeedsConfigFramesByAssignedWindowId() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let persistedWindowId = UUID()
        let assignedWindowId = UUID()
        let ring = [
            SessionConfigFrameEntry(
                signature: "uuid:remembered",
                frame: SessionRectSnapshot(CGRect(x: 10, y: 20, width: 900, height: 600)),
                display: nil,
                lastUsedAt: 123
            )
        ]
        let snapshot = emptyWindowSnapshot(
            windowId: persistedWindowId,
            configFrames: ring
        )

        let createdWindowId = appDelegate.createMainWindow(
            sessionWindowSnapshot: snapshot,
            preferredWindowId: assignedWindowId,
            shouldActivate: false
        )
        defer {
            closeCreatedWindow(appDelegate, windowId: createdWindowId)
            appDelegate.windowConfigFrames.removeValue(forKey: createdWindowId)
            appDelegate.windowConfigFrames.removeValue(forKey: persistedWindowId)
        }

        XCTAssertEqual(createdWindowId, assignedWindowId)
        XCTAssertEqual(appDelegate.windowConfigFrames[createdWindowId], ring)
        XCTAssertNil(appDelegate.windowConfigFrames[persistedWindowId])
    }

    @MainActor
    func testReconcileSkippedDuringSessionRestoreKeepsCaptureFirewallArmed() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        appDelegate.isSettlingScreenChange = true
        appDelegate.isApplyingSessionRestore = true
        defer {
            appDelegate.isApplyingSessionRestore = false
            appDelegate.isSettlingScreenChange = false
        }

        appDelegate.reconcileMainWindowFramesAfterScreenChange()

        XCTAssertTrue(appDelegate.isSettlingScreenChange)
    }

    @MainActor
    func testSessionRestoreCompletionReschedulesArmedScreenChangeReconcile() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let restoredWindowId = UUID()
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 1_000,
            windows: [emptyWindowSnapshot(windowId: restoredWindowId)]
        )
        appDelegate.mainWindowFrameReconcileTask?.cancel()
        appDelegate.mainWindowFrameReconcileTask = nil
        appDelegate.isSettlingScreenChange = true
        defer {
            appDelegate.mainWindowFrameReconcileTask?.cancel()
            appDelegate.mainWindowFrameReconcileTask = nil
            appDelegate.isSettlingScreenChange = false
            appDelegate.isApplyingSessionRestore = false
            closeCreatedWindow(appDelegate, windowId: restoredWindowId)
        }

        let restored = appDelegate.restorePreviousSessionSnapshot(snapshot, shouldActivate: false)

        XCTAssertTrue(restored)
        XCTAssertFalse(appDelegate.isApplyingSessionRestore)
        XCTAssertNotNil(appDelegate.mainWindowFrameReconcileTask)
    }

    // MARK: LRU ring behavior

    func testRingUpsertReplacesSameSignatureAndKeepsLatest() {
        let sig = "uuid:A@0,0,1512x982"
        let first = SessionConfigFrameEntry(
            signature: sig,
            frame: SessionRectSnapshot(CGRect(x: 0, y: 0, width: 900, height: 600)),
            display: nil,
            lastUsedAt: 10
        )
        let second = SessionConfigFrameEntry(
            signature: sig,
            frame: SessionRectSnapshot(CGRect(x: 50, y: 50, width: 950, height: 650)),
            display: nil,
            lastUsedAt: 20
        )
        let ring = SessionConfigFramePolicy.merged(
            SessionConfigFramePolicy.merged([], upserting: first),
            upserting: second
        )
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(ring.first?.frame.cgRect.origin.x, 50)
    }

    func testRingEvictsLeastRecentlyUsedAtCap() {
        var ring: [SessionConfigFrameEntry] = []
        let cap = SessionPersistencePolicy.maxConfigFramesPerWindow
        // Insert cap+2 distinct signatures with increasing recency.
        for i in 0..<(cap + 2) {
            ring = SessionConfigFramePolicy.merged(
                ring,
                upserting: SessionConfigFrameEntry(
                    signature: "uuid:cfg\(i)",
                    frame: SessionRectSnapshot(CGRect(x: 0, y: 0, width: 800, height: 600)),
                    display: nil,
                    lastUsedAt: TimeInterval(i)
                )
            )
        }
        XCTAssertEqual(ring.count, cap)
        // The two oldest (cfg0, cfg1) were evicted; the newest survives.
        XCTAssertNil(SessionConfigFramePolicy.entry(for: "uuid:cfg0", in: ring))
        XCTAssertNil(SessionConfigFramePolicy.entry(for: "uuid:cfg1", in: ring))
        XCTAssertNotNil(SessionConfigFramePolicy.entry(for: "uuid:cfg\(cap + 1)", in: ring))
    }

    // MARK: remembered frame that no longer fits is re-clamped, not applied raw

    func testRememberedFrameLargerThanNewDisplayIsClamped() throws {
        // Remembered a big frame on a 4K external; reconnect to a smaller 1080p
        // display carrying the same stable id at the same origin.
        let bigFrame = CGRect(x: 100, y: 100, width: 3_200, height: 1_800)
        let smallDisplay = geometry(
            "uuid:EXTERNAL",
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 0, y: 0, width: 1_920, height: 1_055),
            displayID: 2
        )
        let resolved = try XCTUnwrap(
            AppDelegate.resolvedWindowFrame(
                from: SessionRectSnapshot(bigFrame),
                // Remembered on a 4K panel — same stable id, now driving 1080p.
                // The larger captured visibleFrame must NOT match the reconnected
                // display, so the oversized frame is clamped rather than preserved.
                display: SessionDisplaySnapshot(
                    displayID: 2,
                    stableID: "uuid:EXTERNAL",
                    frame: SessionRectSnapshot(CGRect(x: 0, y: 0, width: 3_840, height: 2_160)),
                    visibleFrame: SessionRectSnapshot(CGRect(x: 0, y: 0, width: 3_840, height: 2_135))
                ),
                availableDisplays: [smallDisplay],
                fallbackDisplay: smallDisplay
            )
        )
        // Clamped to fit inside the smaller display's visible frame.
        XCTAssertLessThanOrEqual(resolved.maxX, smallDisplay.visibleFrame.maxX + 0.001)
        XCTAssertLessThanOrEqual(resolved.maxY, smallDisplay.visibleFrame.maxY + 0.001)
        XCTAssertGreaterThanOrEqual(resolved.minX, smallDisplay.visibleFrame.minX - 0.001)
        XCTAssertGreaterThanOrEqual(resolved.minY, smallDisplay.visibleFrame.minY - 0.001)
    }
}
