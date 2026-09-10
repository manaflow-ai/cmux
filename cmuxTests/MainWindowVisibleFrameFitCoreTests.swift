import AppKit
import CmuxWindowing
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Main window visible-frame fitting")
struct MainWindowVisibleFrameFitCoreTests {
    private let core = MainWindowVisibleFrameFitCore()

    private static let builtInDisplay = SessionDisplayGeometry(
        displayID: 42,
        stableID: "built-in",
        frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1_512, height: 944)
    )
    private static let rightDisplay = SessionDisplayGeometry(
        displayID: 77,
        stableID: "right-display",
        frame: CGRect(x: 1_512, y: 0, width: 2_560, height: 1_440),
        visibleFrame: CGRect(x: 1_512, y: 0, width: 2_560, height: 1_415)
    )
    private static let minimumWidth: CGFloat = 300
    private static let minimumHeight: CGFloat = 200

    @Test func cutOffLeftWithReachableTitlebarIsFitIntoVisibleFrame() throws {
        let cutOff = CGRect(x: -220, y: 20, width: 1_800, height: 900)

        let fitted = try #require(core.fittedFrame(
            for: cutOff,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ))

        #expect(Self.builtInDisplay.visibleFrame.contains(fitted))
        #expect(fitted.minX == 0)
        #expect(fitted.width == Self.builtInDisplay.visibleFrame.width)
        #expect(fitted.minY == cutOff.minY)
        #expect(fitted.height == cutOff.height)
    }

    @Test func mostlyOffscreenRightIsClampedIntoCurrentScreen() throws {
        let mostlyOffscreen = CGRect(x: 1_440, y: 120, width: 900, height: 600)

        let fitted = try #require(core.fittedFrame(
            for: mostlyOffscreen,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ))

        #expect(Self.builtInDisplay.visibleFrame.contains(fitted))
        #expect(fitted.maxX == Self.builtInDisplay.visibleFrame.maxX)
        #expect(fitted.width == mostlyOffscreen.width)
        #expect(fitted.minY == mostlyOffscreen.minY)
    }

    @Test func oversizedFrameIsShrunkToOnlyRemainingScreen() throws {
        let oversized = CGRect(x: -100, y: -80, width: 3_000, height: 2_000)

        let fitted = try #require(core.fittedFrame(
            for: oversized,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ))

        #expect(fitted == Self.builtInDisplay.visibleFrame)
    }

    @Test func fullyVisibleFrameReturnsNil() {
        let visible = CGRect(x: 100, y: 100, width: 800, height: 600)

        let fitted = core.fittedFrame(
            for: visible,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        )

        #expect(fitted == nil)
    }

    @Test func frameExactlyEqualToVisibleFrameReturnsNil() {
        let fitted = core.fittedFrame(
            for: Self.builtInDisplay.visibleFrame,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        )

        #expect(fitted == nil)
    }

    @Test func degenerateDisplayListsReturnNil() {
        let cutOff = CGRect(x: -220, y: 20, width: 1_800, height: 900)
        let degenerate = SessionDisplayGeometry(
            displayID: 99,
            frame: CGRect(x: 0, y: 0, width: 0, height: 0),
            visibleFrame: CGRect(x: 0, y: 0, width: 0, height: 0)
        )

        #expect(core.fittedFrame(
            for: cutOff,
            displays: [],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ) == nil)
        #expect(core.fittedFrame(
            for: cutOff,
            displays: [degenerate],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ) == nil)
    }

    @Test func fullyVisibleFrameSpanningAdjacentDisplaysReturnsNil() {
        let spanning = CGRect(x: 1_300, y: 80, width: 900, height: 600)

        let fitted = core.fittedFrame(
            for: spanning,
            displays: [Self.builtInDisplay, Self.rightDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        )

        #expect(fitted == nil)
    }

    @Test func cutOffStraddlingFrameTargetsGreatestVisibleOverlapDisplay() throws {
        let straddling = CGRect(x: 1_300, y: -80, width: 900, height: 600)

        let fitted = try #require(core.fittedFrame(
            for: straddling,
            displays: [Self.builtInDisplay, Self.rightDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ))

        #expect(Self.rightDisplay.visibleFrame.contains(fitted))
        #expect(fitted.minY == Self.rightDisplay.visibleFrame.minY)
    }

    @Test func noOverlapFallbackTargetsNearestVisibleFrameEdge() throws {
        let nearWideDisplay = SessionDisplayGeometry(
            displayID: 91,
            frame: CGRect(x: -9_000, y: 0, width: 10_000, height: 1_000),
            visibleFrame: CGRect(x: -9_000, y: 0, width: 10_000, height: 960)
        )
        let fartherNarrowDisplay = SessionDisplayGeometry(
            displayID: 92,
            frame: CGRect(x: 1_200, y: 0, width: 100, height: 1_000),
            visibleFrame: CGRect(x: 1_200, y: 0, width: 100, height: 960)
        )
        let offscreenFrame = CGRect(x: 1_010, y: 100, width: 80, height: 500)

        let fitted = try #require(core.fittedFrame(
            for: offscreenFrame,
            displays: [nearWideDisplay, fartherNarrowDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight
        ))

        #expect(nearWideDisplay.visibleFrame.contains(fitted))
        #expect(fitted.maxX == nearWideDisplay.visibleFrame.maxX)
    }

    @Test func topologySignatureIgnoresSideAndBottomDockInsetChanges() {
        let dockResized = SessionDisplayGeometry(
            displayID: Self.builtInDisplay.displayID,
            stableID: Self.builtInDisplay.stableID,
            frame: Self.builtInDisplay.frame,
            visibleFrame: CGRect(x: 120, y: 80, width: 1_392, height: 864)
        )

        #expect(core.topologySignature(of: [Self.builtInDisplay])
            == core.topologySignature(of: [dockResized]))
    }

    @Test func topologySignatureQuantizesSubpointJitter() {
        let jittered = SessionDisplayGeometry(
            displayID: Self.builtInDisplay.displayID,
            stableID: Self.builtInDisplay.stableID,
            frame: CGRect(x: 0.2, y: -0.3, width: 1_511.7, height: 982.4),
            visibleFrame: CGRect(x: 0.1, y: 0.1, width: 1_511.9, height: 943.6)
        )

        #expect(core.trustedTopologySignature(of: [Self.builtInDisplay])
            == core.trustedTopologySignature(of: [jittered]))
    }

    @Test func trustedTopologySignatureRejectsUntrustedSnapshots() {
        let missingStableID = SessionDisplayGeometry(
            displayID: Self.builtInDisplay.displayID,
            frame: Self.builtInDisplay.frame,
            visibleFrame: Self.builtInDisplay.visibleFrame
        )
        let degenerateVisibleFrame = SessionDisplayGeometry(
            displayID: Self.builtInDisplay.displayID,
            stableID: Self.builtInDisplay.stableID,
            frame: Self.builtInDisplay.frame,
            visibleFrame: .zero
        )

        #expect(core.trustedTopologySignature(of: [missingStableID]) == nil)
        #expect(core.trustedTopologySignature(of: [degenerateVisibleFrame]) == nil)
    }

    @Test func topologySignatureChangesWhenTopInsetChanges() {
        let menuBarMoved = SessionDisplayGeometry(
            displayID: Self.builtInDisplay.displayID,
            stableID: Self.builtInDisplay.stableID,
            frame: Self.builtInDisplay.frame,
            visibleFrame: Self.builtInDisplay.frame
        )

        #expect(core.topologySignature(of: [Self.builtInDisplay])
            != core.topologySignature(of: [menuBarMoved]))
    }

    @Test func topologySignatureIgnoresRawDisplayIDChangesWhenStableIDMatches() {
        let renumbered = SessionDisplayGeometry(
            displayID: 99,
            stableID: Self.builtInDisplay.stableID,
            frame: Self.builtInDisplay.frame,
            visibleFrame: Self.builtInDisplay.visibleFrame
        )

        #expect(core.topologySignature(of: [Self.builtInDisplay])
            == core.topologySignature(of: [renumbered]))
    }

    @Test func topologySignatureChangesWhenStableDisplayIdentityChanges() {
        let differentDisplay = SessionDisplayGeometry(
            displayID: Self.builtInDisplay.displayID,
            stableID: "replacement-display",
            frame: Self.builtInDisplay.frame,
            visibleFrame: Self.builtInDisplay.visibleFrame
        )

        #expect(core.topologySignature(of: [Self.builtInDisplay])
            != core.topologySignature(of: [differentDisplay]))
    }

    @Test func fullscreenReconnectUsesTheTargetDisplayVisibleFrame() throws {
        let external = SessionDisplayGeometry(
            displayID: 77,
            stableID: "external",
            frame: CGRect(x: 1_512, y: -112, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 1_512, y: -112, width: 2_560, height: 1_416)
        )
        let stale = CGRect(x: 1_512, y: -497, width: 2_560, height: 1_403)

        let fitted = try #require(core.fittedFullscreenFrame(
            for: stale,
            displays: [Self.builtInDisplay, external]
        ))

        #expect(fitted == CGRect(x: 1_512, y: -112, width: 2_560, height: 1_416))
    }

    @Test func fullscreenReconnectPreservesPhysicalDisplayFrame() {
        let external = SessionDisplayGeometry(
            displayID: 77,
            stableID: "external",
            frame: CGRect(x: 1_512, y: -112, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 1_512, y: -112, width: 2_560, height: 1_416)
        )

        #expect(core.fittedFullscreenFrame(
            for: external.frame,
            displays: [Self.builtInDisplay, external]
        ) == nil)
    }

    @Test func tiledFullscreenFrameIsNotExpandedToTheWholeDisplay() {
        let external = SessionDisplayGeometry(
            displayID: 77,
            stableID: "external",
            frame: CGRect(x: 1_512, y: -112, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 1_512, y: -112, width: 2_560, height: 1_416)
        )
        let tiled = CGRect(x: 1_512, y: -112, width: 1_280, height: 1_440)

        #expect(core.fittedFullscreenFrame(
            for: tiled,
            displays: [Self.builtInDisplay, external]
        ) == nil)
    }

    @Test func fullscreenVisibleFrameWithBottomDockInsetIsPreserved() {
        let external = SessionDisplayGeometry(
            displayID: 77,
            stableID: "external",
            frame: CGRect(x: 1_512, y: -112, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 1_512, y: -32, width: 2_560, height: 1_336)
        )

        #expect(core.fittedFullscreenFrame(
            for: external.visibleFrame,
            displays: [Self.builtInDisplay, external]
        ) == nil)
    }

    @Test func restoreClampsReachableTitlebarFrameCutOffPastLeftEdgeWhenDisplayChanged() throws {
        let savedFrame = SessionRectSnapshot(x: -220, y: 20, width: 1_800, height: 900)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 42,
            frame: SessionRectSnapshot(x: -512, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: -512, y: 0, width: 2_560, height: 1_415)
        )
        let currentDisplay = Self.builtInDisplay

        let restored = try #require(AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [currentDisplay],
            fallbackDisplay: currentDisplay
        ))

        #expect(currentDisplay.visibleFrame.contains(restored))
        #expect(restored.minX == 0)
        #expect(restored.width == currentDisplay.visibleFrame.width)
        #expect(restored.minY == CGFloat(savedFrame.y))
        #expect(restored.height == CGFloat(savedFrame.height))
    }

    @Test func restorePreservesVisibleFrameSpanningDisplaysWhenDisplaySnapshotChanged() throws {
        let savedFrame = SessionRectSnapshot(x: 1_300, y: 80, width: 900, height: 600)
        let staleDisplay = SessionDisplaySnapshot(
            displayID: 999,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 1_512, height: 982),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_512, height: 944)
        )

        let restored = try #require(AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: staleDisplay,
            availableDisplays: [Self.builtInDisplay, Self.rightDisplay],
            fallbackDisplay: Self.builtInDisplay
        ))

        #expect(restored == savedFrame.cgRect)
    }

    @Test func restoreFitsCutOffFrameToCurrentDisplayWithGreatestOverlap() throws {
        let savedFrame = SessionRectSnapshot(x: 1_500, y: -60, width: 900, height: 600)
        let staleBuiltInDisplay = SessionDisplaySnapshot(
            displayID: Self.builtInDisplay.displayID,
            stableID: Self.builtInDisplay.stableID,
            frame: SessionRectSnapshot(x: -40, y: 0, width: 1_512, height: 982),
            visibleFrame: SessionRectSnapshot(x: -40, y: 0, width: 1_512, height: 900)
        )

        let restored = try #require(AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: staleBuiltInDisplay,
            availableDisplays: [Self.builtInDisplay, Self.rightDisplay],
            fallbackDisplay: Self.builtInDisplay
        ))

        #expect(Self.rightDisplay.visibleFrame.contains(restored))
        #expect(restored.minX == Self.rightDisplay.visibleFrame.minX)
        #expect(restored.minY == Self.rightDisplay.visibleFrame.minY)
        #expect(restored.width == CGFloat(savedFrame.width))
        #expect(restored.height == CGFloat(savedFrame.height))
    }

    @Test func displayDisconnectMovesRightStrandedWindowIntoRemainingDisplay() throws {
        let stranded = CGRect(x: 1_520, y: 120, width: 900, height: 600)

        let repaired = try #require(core.repairedFrame(
            for: stranded,
            displays: [Self.builtInDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight,
            mode: .visibleFrame
        ))

        #expect(Self.builtInDisplay.visibleFrame.contains(repaired))
        #expect(repaired.width == stranded.width)
        #expect(repaired.height == stranded.height)
    }

    @Test func nativeFullscreenReconnectDefersToAppKit() {
        let external = SessionDisplayGeometry(
            displayID: 88,
            stableID: "external-reconnected",
            frame: CGRect(x: 1_512, y: -211, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 1_512, y: -187, width: 2_560, height: 1_416)
        )
        let staleFullscreenFrame = CGRect(x: 1_512, y: -497, width: 2_560, height: 1_403)

        let repaired = core.repairedFrame(
            for: staleFullscreenFrame,
            displays: [Self.builtInDisplay, external],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight,
            mode: .nativeFullscreen
        )

        #expect(repaired == nil)
    }

    @Test func zoomedWindowAppActivationRestoresCurrentVisibleFrame() throws {
        let shrunkZoomedFrame = CGRect(x: 0, y: 0, width: 2_560, height: 1_100)

        let repaired = try #require(core.repairedFrame(
            for: shrunkZoomedFrame,
            displays: [Self.rightDisplay],
            minimumWidth: Self.minimumWidth,
            minimumHeight: Self.minimumHeight,
            mode: .zoomed
        ))

        #expect(repaired == Self.rightDisplay.visibleFrame)
    }
}

@Suite("Main window zoom intent")
struct MainWindowZoomIntentTests {
    @Test func userPlacementClearsZoomIntent() {
        var state = MainWindowZoomIntentState()
        state.recordZoom(isZoomed: true)

        state.recordUserPlacement()

        #expect(!state.wantsZoomedFrame)
    }
}

@MainActor
@Suite("Main window zoom placement callbacks", .serialized)
struct MainWindowZoomPlacementTests {
    @Test func titlebarClickWithoutMovementPreservesZoomRecovery() throws {
        try withZoomedWindow { window, _ in
            let mouseDown = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 200, y: window.frame.height - 12),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
            let beforeClick = window.frame

            window.performDrag(with: mouseDown)

            #expect(window.frame == beforeClick)
            shrinkAndExpectZoomRecovery(window)
        }
    }

    @Test func confirmedWindowMoveClearsZoomIntent() throws {
        try withZoomedWindow { window, delegate in
            delegate.windowWillMove?(Notification(name: NSWindow.willMoveNotification, object: window))
            var placed = window.frame
            placed.origin.x += 40
            placed.size.width -= 100
            window.setFrame(placed, display: false)

            expectActivationPreservesPlacement(window)
        }
    }

    @Test func nativeTilingLiveResizeClearsZoomWithoutCallingSetFrameDuringTracking() throws {
        try withZoomedWindow { window, delegate in
            // AppKit's native tile animation emits live-resize callbacks but
            // bypasses CmuxMainWindow.setFrame throughout the animation.
            delegate.windowWillStartLiveResize?(Notification(
                name: NSWindow.willStartLiveResizeNotification,
                object: window
            ))
            var tiled = window.frame
            tiled.size.width /= 2
            window.setFrame(tiled, display: false)
            delegate.windowDidEndLiveResize?(Notification(
                name: NSWindow.didEndLiveResizeNotification,
                object: window
            ))

            expectActivationPreservesPlacement(window)
        }
    }

    @Test func automaticOriginChangesPreserveZoomRecovery() throws {
        try withZoomedWindow { window, _ in
            window.setFrameOrigin(NSPoint(x: window.frame.minX + 20, y: window.frame.minY))
            shrinkAndExpectZoomRecovery(window)
        }
    }

    @Test func foreignWindowPlacementCallbacksDoNotClearZoomIntent() throws {
        try withZoomedWindow { window, delegate in
            let foreign = NSWindow(
                contentRect: NSRect(x: 50, y: 50, width: 400, height: 300),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            foreign.isReleasedWhenClosed = false
            defer { foreign.close() }
            delegate.windowWillMove?(Notification(name: NSWindow.willMoveNotification, object: foreign))
            delegate.windowWillStartLiveResize?(Notification(
                name: NSWindow.willStartLiveResizeNotification,
                object: foreign
            ))

            shrinkAndExpectZoomRecovery(window)
        }
    }

    private func withZoomedWindow(
        _ body: (CmuxMainWindow, any NSWindowDelegate) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let window = CmuxMainWindow(
            contentRect: NSRect(x: screen.visibleFrame.minX + 50, y: screen.visibleFrame.minY + 50, width: 600, height: 400),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = MainWindowController(window: window)
        defer { window.close() }
        window.zoom(nil)
        try #require(window.isZoomed)
        try body(window, controller)
    }

    private func shrinkAndExpectZoomRecovery(_ window: CmuxMainWindow) {
        var shrunk = window.frame
        shrunk.size.height -= 80
        window.setFrameForManagedPlacement(shrunk, display: false)

        #expect(!window.isZoomed)
        #expect(window.cmuxWantsZoomedFrame)
        repairOnActivation(window)
        #expect(NSScreen.screens.contains { $0.visibleFrame == window.frame })
    }

    private func expectActivationPreservesPlacement(_ window: CmuxMainWindow) {
        let placed = window.frame
        #expect(!window.isZoomed)
        #expect(!window.cmuxWantsZoomedFrame)
        repairOnActivation(window)
        #expect(window.frame == placed)
    }

    private func repairOnActivation(_ window: CmuxMainWindow) {
        let displays = NSScreen.screens.enumerated().map { index, screen in
            SessionDisplayGeometry(displayID: UInt32(index + 1), frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
        MainWindowFrameReconciler().repair(displays: displays, windows: [window], trigger: .applicationActivation)
    }
}
