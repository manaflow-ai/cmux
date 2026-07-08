import AppKit
import CmuxWindowing
import struct CmuxWorkspaces.SessionRectSnapshot
import struct CmuxWorkspaces.SessionSidebarSnapshot
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Round-trip coverage for per-monitor window-geometry memory (issue #2135).
@Suite(.serialized)
@MainActor
struct AppDelegateDisplayConfigRestoreTests {
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

    private func testAppDelegate() -> AppDelegate {
        AppDelegate.shared ?? AppDelegate()
    }

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

    @Test
    func windowFrameIsRestoredToExternalMonitorAfterReconnect() throws {
        // 1. Docked: built-in + external. User's window lives on the external.
        let dockedSignature = try #require(
            [builtIn, external].displayConfigurationSignature()
        )
        let externalWindowFrame = CGRect(x: -1_600, y: 200, width: 1_000, height: 700)

        // Remember that frame under the docked signature.
        var ring = SessionConfigFrameRing().upserting(
            SessionConfigFrameEntry(
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
        let laptopSignature = try #require(
            [builtIn].displayConfigurationSignature()
        )
        #expect(dockedSignature != laptopSignature)
        // Simulate the built-in capture landing in its own slot.
        ring = ring.upserting(
            SessionConfigFrameEntry(
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
        let externalEntry = try #require(ring.entry(for: dockedSignature))
        #expect(externalEntry.frame.cgRect == externalWindowFrame)

        // 3. Reconnect: signature returns to docked. Restore resolves the
        //    remembered external frame back onto the external monitor.
        let restored = AppDelegate.resolvedWindowFrame(
            from: externalEntry.frame,
            display: externalEntry.display,
            availableDisplays: [builtIn, external],
            fallbackDisplay: builtIn
        )
        let resolved = try #require(restored)
        #expect(resolved == externalWindowFrame, "remembered external frame should round-trip exactly")
        #expect(externalVisible.intersects(resolved), "restored frame lands on the external monitor")
    }

    @Test
    func stableDisplayIdentityWinsWhenDisplayIDIsReassigned() throws {
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

        let restored = try #require(
            AppDelegate.resolvedWindowFrame(
                from: SessionRectSnapshot(savedFrame),
                display: savedDisplay,
                availableDisplays: [builtInWithOldExternalID, externalWithNewID],
                fallbackDisplay: builtInWithOldExternalID
            )
        )

        #expect(restored == savedFrame)
        #expect(externalVisible.intersects(restored))
        #expect(!builtInVisible.intersects(restored))
    }

    @Test
    func savedGeometryFallbackIsUsedWhenLiveStableIdentityIsMissing() throws {
        let savedFrame = CGRect(x: -1_600, y: 200, width: 1_000, height: 700)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            stableID: "uuid:EXTERNAL",
            frame: SessionRectSnapshot(externalFrame),
            visibleFrame: SessionRectSnapshot(externalVisible)
        )
        let liveExternalWithoutStableID = AppDelegate.SessionDisplayGeometry(
            displayID: 99,
            stableID: nil,
            frame: externalFrame,
            visibleFrame: externalVisible
        )

        let restored = try #require(
            AppDelegate.resolvedWindowFrame(
                from: SessionRectSnapshot(savedFrame),
                display: savedDisplay,
                availableDisplays: [builtIn, liveExternalWithoutStableID],
                fallbackDisplay: builtIn
            )
        )

        #expect(restored == savedFrame)
        #expect(!builtInVisible.intersects(restored))
    }

    @Test
    func duplicateStableDisplayIdentityUsesSavedGeometryTieBreak() throws {
        let leftFrame = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        let rightFrame = CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080)
        let left = geometry("uuid:SAME", leftFrame, leftFrame, displayID: 7)
        let right = geometry("uuid:SAME", rightFrame, rightFrame, displayID: 8)
        let savedFrame = CGRect(x: 1_700, y: 120, width: 900, height: 650)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 42,
            stableID: "uuid:SAME",
            frame: SessionRectSnapshot(rightFrame),
            visibleFrame: SessionRectSnapshot(rightFrame)
        )

        let restored = try #require(
            AppDelegate.resolvedWindowFrame(
                from: SessionRectSnapshot(savedFrame),
                display: savedDisplay,
                availableDisplays: [left, right],
                fallbackDisplay: builtIn
            )
        )

        #expect(restored == savedFrame)
        #expect(rightFrame.intersects(restored))
        #expect(!leftFrame.intersects(restored))
    }

    @Test
    func restorePrefersCurrentConfigurationFrameEntry() throws {
        let dockedSignature = try #require([builtIn, external].displayConfigurationSignature())
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

        let restored = try #require(
            AppDelegate.resolvedWindowFrame(
                from: snapshot,
                currentSignature: dockedSignature,
                availableDisplays: [builtIn, external],
                fallbackDisplay: builtIn
            )
        )
        let startup = try #require(
            AppDelegate.resolvedStartupPrimaryWindowFrame(
                primarySnapshot: snapshot,
                fallbackFrame: nil,
                fallbackDisplaySnapshot: nil,
                availableDisplays: [builtIn, external],
                fallbackDisplay: builtIn
            )
        )

        #expect(restored == externalFrameForDock)
        #expect(startup == externalFrameForDock)
    }

    @Test
    func snapshotBackedWindowCreationSeedsConfigFramesByAssignedWindowId() {
        let appDelegate = testAppDelegate()
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

        #expect(createdWindowId == assignedWindowId)
        #expect(appDelegate.windowConfigFrames[createdWindowId]?.entries == ring)
        #expect(appDelegate.windowConfigFrames[persistedWindowId] == nil)
    }

    @Test
    func snapshotBackedWindowCreationSanitizesConfigFrameRing() {
        let appDelegate = testAppDelegate()
        let assignedWindowId = UUID()
        let cap = SessionPersistencePolicy.maxConfigFramesPerWindow
        var ring: [SessionConfigFrameEntry] = (0..<(cap + 3)).map { index in
            SessionConfigFrameEntry(
                signature: "cfg\(index)",
                frame: SessionRectSnapshot(CGRect(x: CGFloat(index), y: 0, width: 900, height: 600)),
                display: nil,
                lastUsedAt: TimeInterval(index)
            )
        }
        ring.append(SessionConfigFrameEntry(
            signature: "cfg\(cap + 2)",
            frame: SessionRectSnapshot(CGRect(x: 999, y: 0, width: 900, height: 600)),
            display: nil,
            lastUsedAt: 999
        ))
        let snapshot = emptyWindowSnapshot(configFrames: ring)

        let createdWindowId = appDelegate.createMainWindow(
            sessionWindowSnapshot: snapshot,
            preferredWindowId: assignedWindowId,
            shouldActivate: false
        )
        defer {
            closeCreatedWindow(appDelegate, windowId: createdWindowId)
            appDelegate.windowConfigFrames.removeValue(forKey: createdWindowId)
        }

        let stored = appDelegate.windowConfigFrames[createdWindowId] ?? SessionConfigFrameRing()
        #expect(stored.entries.count == cap)
        #expect(stored.entry(for: "cfg\(cap + 2)")?.frame.cgRect.minX == 999)
        #expect(stored.entry(for: "cfg0") == nil)
    }

    @Test
    func reconcileSkippedDuringSessionRestoreKeepsCaptureFirewallArmed() {
        let appDelegate = testAppDelegate()
        appDelegate.isScreenChangeCaptureSuppressed = true
        appDelegate.isApplyingSessionRestore = true
        defer {
            appDelegate.isApplyingSessionRestore = false
            appDelegate.isScreenChangeCaptureSuppressed = false
            appDelegate.screenChangeCaptureSuppressionSignature = nil
            appDelegate.screenChangeCaptureSuppressionSignatureGeneration = nil
            appDelegate.screenChangeReconcileRetryBudget = 0
        }
        appDelegate.reconcileMainWindowFramesAfterScreenChange()
        #expect(appDelegate.isScreenChangeCaptureSuppressed)
    }

    @Test
    func captureSuppressionOnlyReleasesAfterReconcileRecordsSignature() {
        let appDelegate = testAppDelegate()
        appDelegate.isScreenChangeCaptureSuppressed = true
        appDelegate.screenChangeCaptureSuppressionSignature = nil
        defer {
            appDelegate.isScreenChangeCaptureSuppressed = false
            appDelegate.screenChangeCaptureSuppressionSignature = nil
            appDelegate.screenChangeCaptureSuppressionSignatureGeneration = nil
            appDelegate.screenChangeReconcileRetryBudget = 0
        }
        #expect(!appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: "uuid:A"))
        appDelegate.handleDisplayReconfiguration(isBeginning: true)
        appDelegate.screenChangeCaptureSuppressionSignature = "uuid:A"
        appDelegate.screenChangeCaptureSuppressionSignatureGeneration = appDelegate.displayReconfigurationGeneration
        #expect(appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: "uuid:A"))
        appDelegate.handleDisplayReconfiguration(isBeginning: false)
        #expect(!appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: "uuid:A"))
        appDelegate.screenChangeCaptureSuppressionSignatureGeneration = appDelegate.displayReconfigurationGeneration
        appDelegate.screenChangeCaptureSuppressionSignature = "uuid:A"
        #expect(appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: "uuid:A"))
        #expect(!appDelegate.shouldReleaseScreenChangeCaptureSuppression(for: "uuid:B"))
    }
    @Test
    func sessionRestoreCompletionRunsArmedScreenChangeReconcile() throws {
        let appDelegate = testAppDelegate()
        try #require(!NSScreen.screens.isEmpty)
        let restoredWindowId = UUID()
        let snapshot = AppSessionSnapshot(
            version: AppSessionSnapshot.currentSchemaVersion,
            createdAt: 1_000,
            windows: [emptyWindowSnapshot(windowId: restoredWindowId)]
        )
        appDelegate.isScreenChangeCaptureSuppressed = true
        defer {
            appDelegate.isScreenChangeCaptureSuppressed = false
            appDelegate.screenChangeCaptureSuppressionSignature = nil
            appDelegate.screenChangeReconcileRetryBudget = 0
            appDelegate.isApplyingSessionRestore = false
            closeCreatedWindow(appDelegate, windowId: restoredWindowId)
        }
        let restored = appDelegate.restorePreviousSessionSnapshot(snapshot, shouldActivate: false)
        #expect(restored)
        #expect(!appDelegate.isApplyingSessionRestore)
        #expect(appDelegate.isScreenChangeCaptureSuppressed)
    }
    // MARK: LRU ring behavior
    @Test
    func ringUpsertReplacesSameSignatureAndKeepsLatest() {
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
        let ring = SessionConfigFrameRing().upserting(first).upserting(second)
        #expect(ring.entries.count == 1)
        #expect(ring.entries.first?.frame.cgRect.origin.x == 50)
    }

    @Test
    func ringEvictsLeastRecentlyUsedAtCap() {
        var ring = SessionConfigFrameRing()
        let cap = SessionPersistencePolicy.maxConfigFramesPerWindow
        // Insert cap+2 distinct signatures with increasing recency.
        for i in 0..<(cap + 2) {
            ring = ring.upserting(
                SessionConfigFrameEntry(
                    signature: "uuid:cfg\(i)",
                    frame: SessionRectSnapshot(CGRect(x: 0, y: 0, width: 800, height: 600)),
                    display: nil,
                    lastUsedAt: TimeInterval(i)
                )
            )
        }
        #expect(ring.entries.count == cap)
        // The two oldest (cfg0, cfg1) were evicted; the newest survives.
        #expect(ring.entry(for: "uuid:cfg0") == nil)
        #expect(ring.entry(for: "uuid:cfg1") == nil)
        #expect(ring.entry(for: "uuid:cfg\(cap + 1)") != nil)
    }

    // MARK: remembered frame that no longer fits is re-clamped, not applied raw

    @Test
    func rememberedFrameLargerThanNewDisplayIsClamped() throws {
        // Remembered a big frame on a 4K external; reconnect to a smaller 1080p
        // display carrying the same stable id at the same origin.
        let bigFrame = CGRect(x: 100, y: 100, width: 3_200, height: 1_800)
        let smallDisplay = geometry(
            "uuid:EXTERNAL",
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            CGRect(x: 0, y: 0, width: 1_920, height: 1_055),
            displayID: 2
        )
        let resolved = try #require(
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
        #expect(resolved.maxX <= smallDisplay.visibleFrame.maxX + 0.001)
        #expect(resolved.maxY <= smallDisplay.visibleFrame.maxY + 0.001)
        #expect(resolved.minX >= smallDisplay.visibleFrame.minX - 0.001)
        #expect(resolved.minY >= smallDisplay.visibleFrame.minY - 0.001)
    }
}
