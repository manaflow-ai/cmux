import AppKit
import CmuxWindowing
import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct WorkspaceFloatingDockScreenPlacementTests {
    private func display(
        id: UInt32,
        stableID: String,
        frame: CGRect
    ) -> SessionDisplayGeometry {
        SessionDisplayGeometry(
            displayID: id,
            stableID: stableID,
            frame: frame,
            visibleFrame: frame
        )
    }

    private func snapshot(
        id: UInt32,
        stableID: String,
        frame: CGRect
    ) -> SessionDisplaySnapshot {
        SessionDisplaySnapshot(
            displayID: id,
            stableID: stableID,
            frame: SessionRectSnapshot(frame),
            visibleFrame: SessionRectSnapshot(frame)
        )
    }

    @Test
    func screenResizePreservesRelativeCenterAndWindowSize() throws {
        let oldDisplayFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let resizedDisplay = display(
            id: 8,
            stableID: "display-a",
            frame: CGRect(x: 0, y: 0, width: 2_000, height: 1_600)
        )
        let oldWindowFrame = CGRect(x: 500, y: 300, width: 400, height: 300)

        let resolved = try #require(WorkspaceFloatingDockScreenPlacement.resolvedFrame(
            currentSignature: "resized",
            configFrames: SessionConfigFrameRing(),
            fallbackFrame: oldWindowFrame,
            fallbackDisplay: snapshot(id: 8, stableID: "display-a", frame: oldDisplayFrame),
            availableDisplays: [resizedDisplay],
            fallbackDisplayGeometry: resizedDisplay
        ))

        #expect(resolved == CGRect(x: 1_200, y: 750, width: 400, height: 300))
    }

    @Test
    func returningDisplayConfigurationRestoresExactRememberedFrame() throws {
        let builtIn = display(
            id: 1,
            stableID: "built-in",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let external = display(
            id: 2,
            stableID: "external",
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        )
        let rememberedFrame = CGRect(x: 2_100, y: 420, width: 520, height: 380)
        let rememberedEntry = SessionConfigFrameEntry(
            signature: "dual",
            frame: SessionRectSnapshot(rememberedFrame),
            display: snapshot(id: 2, stableID: "external", frame: external.frame),
            lastUsedAt: 1
        )

        let resolved = try #require(WorkspaceFloatingDockScreenPlacement.resolvedFrame(
            currentSignature: "dual",
            configFrames: SessionConfigFrameRing(entries: [rememberedEntry]),
            fallbackFrame: CGRect(x: 200, y: 200, width: 520, height: 380),
            fallbackDisplay: snapshot(id: 1, stableID: "built-in", frame: builtIn.frame),
            availableDisplays: [builtIn, external],
            fallbackDisplayGeometry: builtIn
        ))

        #expect(resolved == rememberedFrame)
    }

    @Test
    func removedDisplayMovesWindowRelativelyOntoFallbackDisplay() throws {
        let builtIn = display(
            id: 1,
            stableID: "built-in",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let externalFrame = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        let externalWindowFrame = CGRect(x: 1_500, y: 300, width: 400, height: 300)

        let resolved = try #require(WorkspaceFloatingDockScreenPlacement.resolvedFrame(
            currentSignature: "single",
            configFrames: SessionConfigFrameRing(),
            fallbackFrame: externalWindowFrame,
            fallbackDisplay: snapshot(id: 2, stableID: "external", frame: externalFrame),
            availableDisplays: [builtIn],
            fallbackDisplayGeometry: builtIn
        ))

        #expect(resolved == CGRect(x: 500, y: 300, width: 400, height: 300))
    }

    @Test
    func parkedWindowFollowsOwnerToAnotherDisplay() {
        let originalScreen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let destinationScreen = CGRect(x: 1_000, y: 0, width: 2_000, height: 1_600)
        let snapshot = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: CGRect(x: 500, y: 300, width: 400, height: 300),
            visibleScreenFrame: originalScreen
        )

        let migrated = snapshot.migrated(toVisibleScreenFrame: destinationScreen)

        #expect(migrated.restoreFrame == CGRect(x: 2_200, y: 750, width: 400, height: 300))
        #expect(migrated.visibleScreenFrame == destinationScreen)
        #expect(destinationScreen.intersection(migrated.parkedFrame).width == 48)
    }

    @Test
    func parkedWindowKeepsItsNativeSizeAtAnInternalRightEdge() {
        let ownerScreen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let rightNeighbor = CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        let snapshot = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: CGRect(x: 240, y: 180, width: 620, height: 420),
            visibleScreenFrame: ownerScreen,
            availableScreenFrames: [ownerScreen, rightNeighbor]
        )

        let parkedVisibleFrame = ownerScreen.intersection(snapshot.parkedFrame)
        #expect(parkedVisibleFrame.width == 48)
        #expect(parkedVisibleFrame.maxX == ownerScreen.maxX)
        #expect(snapshot.parkedFrame.size == snapshot.restoreFrame.size)
        let revealedVisibleFrame = ownerScreen.intersection(snapshot.revealedFrame)
        #expect(revealedVisibleFrame.width == 144)
        #expect(revealedVisibleFrame.maxX == ownerScreen.maxX)
        #expect(snapshot.revealedFrame.size == snapshot.restoreFrame.size)
        #expect(snapshot.containsRevealedPoint(CGPoint(
            x: revealedVisibleFrame.minX - 10,
            y: snapshot.revealedFrame.midY
        )))
        #expect(!snapshot.containsRevealedPoint(CGPoint(
            x: revealedVisibleFrame.minX - 16,
            y: snapshot.revealedFrame.midY
        )))
    }

    @Test
    func parkedWindowMigrationKeepsTheRightEdgeOnTheDestinationDisplay() {
        let leftScreen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let rightScreen = CGRect(x: 1_440, y: -180, width: 1_920, height: 1_080)
        let screens = [leftScreen, rightScreen]
        let snapshot = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: CGRect(x: 1_920, y: 240, width: 620, height: 420),
            visibleScreenFrame: rightScreen,
            availableScreenFrames: screens
        )

        #expect(rightScreen.intersection(snapshot.parkedFrame).maxX == rightScreen.maxX)
        let migrated = snapshot.migrated(
            toVisibleScreenFrame: leftScreen,
            availableScreenFrames: screens
        )

        #expect(migrated.restoreFrame.size == snapshot.restoreFrame.size)
        let migratedVisibleFrame = leftScreen.intersection(migrated.parkedFrame)
        #expect(migratedVisibleFrame.width == 48)
        #expect(migratedVisibleFrame.maxX == leftScreen.maxX)
        #expect(migrated.parkedFrame.size == migrated.restoreFrame.size)
    }

    @Test
    func parkedWindowStackKeepsTheRightEdgeAcrossUnevenDisplays() {
        let ownerScreen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let upperRightNeighbor = CGRect(x: 1_440, y: 450, width: 1_920, height: 630)
        let snapshots = WorkspaceFloatingDockParkingSnapshot.arranged(
            restoreFrames: [
                CGRect(x: 240, y: 100, width: 620, height: 300),
                CGRect(x: 240, y: 500, width: 620, height: 300),
            ],
            visibleScreenFrame: ownerScreen,
            availableScreenFrames: [ownerScreen, upperRightNeighbor]
        )

        #expect(snapshots.allSatisfy {
            ownerScreen.intersection($0.parkedFrame).maxX == ownerScreen.maxX
        })
        #expect(snapshots.allSatisfy { $0.parkedFrame.size == $0.restoreFrame.size })
    }
}

@Suite(.serialized)
struct WorkspaceFloatingDockParkingRegressionTests {
    @Test
    func parkingKeepsARecognizableAdaptiveWindowSlice() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let regularWindow = CGRect(x: 240, y: 180, width: 620, height: 420)
        let narrowWindow = CGRect(x: 240, y: 180, width: 80, height: 420)

        let regularParked = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: regularWindow,
            visibleScreenFrame: screen
        ).parkedFrame
        let narrowParked = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: narrowWindow,
            visibleScreenFrame: screen
        ).parkedFrame

        #expect(screen.intersection(regularParked).width == 48)
        #expect(screen.intersection(narrowParked).width == 16)
        #expect(regularParked.size == regularWindow.size)
        #expect(narrowParked.size == narrowWindow.size)
    }

    @Test
    func parkingSnapshotKeepsExplicitRestoreRevealAndToleranceFrames() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let restoreFrame = CGRect(x: 240, y: 180, width: 620, height: 420)
        let snapshot = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: restoreFrame,
            visibleScreenFrame: screen
        )

        #expect(snapshot.restoreFrame == restoreFrame)
        #expect(screen.intersection(snapshot.parkedFrame).width == 48)
        #expect(screen.intersection(snapshot.revealedFrame).width == 144)
        #expect(snapshot.parkedFrame.size == restoreFrame.size)
        #expect(snapshot.revealedFrame.size == restoreFrame.size)
        #expect(snapshot.hoverActivationFrame.width == 144)
        #expect(snapshot.containsHoverActivationPoint(CGPoint(
            x: snapshot.restingVisibleFrame.minX - 80,
            y: snapshot.restingVisibleFrame.midY
        )))
        #expect(!snapshot.containsHoverActivationPoint(CGPoint(
            x: snapshot.restingVisibleFrame.minX - 97,
            y: snapshot.restingVisibleFrame.midY
        )))
        #expect(snapshot.containsRevealedPoint(CGPoint(
            x: snapshot.revealedFrame.minX - 10,
            y: snapshot.revealedFrame.midY
        )))
        #expect(!snapshot.containsRevealedPoint(CGPoint(
            x: snapshot.revealedFrame.minX - 16,
            y: snapshot.revealedFrame.midY
        )))
    }

    @Test
    func parkingArrangesOverlappingWindowsIntoTargetableBands() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let restoreFrames = (0..<4).map { _ in
            CGRect(x: 240, y: 180, width: 620, height: 420)
        }

        let snapshots = WorkspaceFloatingDockParkingSnapshot.arranged(
            restoreFrames: restoreFrames,
            visibleScreenFrame: screen
        )

        #expect(snapshots.count == restoreFrames.count)
        for index in snapshots.indices.dropFirst() {
            #expect(
                snapshots[index].parkedFrame.minY
                    - snapshots[index - 1].parkedFrame.minY
                    == WorkspaceFloatingDockParkingSnapshot.preferredTargetHeight
            )
        }
        #expect(snapshots.allSatisfy {
            $0.parkedFrame.minY >= screen.minY && $0.parkedFrame.maxY <= screen.maxY
        })
        for index in snapshots.indices.dropFirst() {
            #expect(
                snapshots[index - 1].hoverActivationFrame.maxY
                    <= snapshots[index].hoverActivationFrame.minY
            )
        }
    }

    @Test
    func parkingCompressesLargeStacksWithoutMovingAnyWindowOffscreen() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let restoreFrames = (0..<10).map { _ in
            CGRect(x: 240, y: 180, width: 620, height: 420)
        }

        let snapshots = WorkspaceFloatingDockParkingSnapshot.arranged(
            restoreFrames: restoreFrames,
            visibleScreenFrame: screen
        )

        #expect(snapshots.count == restoreFrames.count)
        #expect(snapshots.allSatisfy {
            $0.parkedFrame.minY >= screen.minY && $0.parkedFrame.maxY <= screen.maxY
        })
        for index in snapshots.indices.dropFirst() {
            #expect(snapshots[index].parkedFrame.minY > snapshots[index - 1].parkedFrame.minY)
        }
    }

    @Test
    @MainActor
    func newerParkingLayoutWinsOverAnOlderAnimationCompletion() async throws {
        _ = NSApplication.shared
        let noteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-floating-parking-generation-\(UUID().uuidString).md")
        try "".write(to: noteURL, atomically: true, encoding: .utf8)
        let parent = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceFloatingDock(
            id: UUID(),
            workspaceId: UUID(),
            title: "Animated",
            frame: CGRect(x: 40, y: 40, width: 520, height: 380),
            noteFilePath: noteURL.path,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        let controller = WorkspaceFloatingDockWindowController(
            dock: dock,
            parentWindow: parent,
            onCloseRequest: { _ in }
        )
        defer {
            controller.teardown()
            dock.close()
            parent.close()
            try? FileManager.default.removeItem(at: noteURL)
        }
        controller.show(focus: false)
        let first = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: CGRect(x: 200, y: 200, width: 520, height: 380),
            visibleScreenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let latest = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: CGRect(x: 2_900, y: 20, width: 520, height: 380),
            visibleScreenFrame: CGRect(x: 2_560, y: -358, width: 1_728, height: 1_117)
        )

        dock.setStashed(true)
        controller.stash(snapshot: first, completion: {})
        controller.showStashed(snapshot: latest, animated: false)
        try await Task.sleep(nanoseconds: 350_000_000)

        #expect(controller.window?.frame == latest.parkedFrame)
    }

    @Test
    @MainActor
    func internalRightBoundaryNeverResizesTheRealPanel() throws {
        _ = NSApplication.shared
        let visibleFrame = try #require(NSScreen.main?.visibleFrame)
        let rightNeighbor = CGRect(
            x: visibleFrame.maxX,
            y: visibleFrame.minY,
            width: 1_000,
            height: visibleFrame.height
        )
        let restoreFrame = CGRect(
            x: visibleFrame.midX - 260,
            y: visibleFrame.midY - 190,
            width: 520,
            height: 380
        )
        let noteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-floating-parking-size-invariant-\(UUID().uuidString).md")
        try "".write(to: noteURL, atomically: true, encoding: .utf8)
        let parent = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceFloatingDock(
            id: UUID(),
            workspaceId: UUID(),
            title: "Full Size",
            frame: CGRect(x: 40, y: 40, width: 520, height: 380),
            noteFilePath: noteURL.path,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        let controller = WorkspaceFloatingDockWindowController(
            dock: dock,
            parentWindow: parent,
            onCloseRequest: { _ in }
        )
        defer {
            controller.teardown()
            dock.close()
            parent.close()
            try? FileManager.default.removeItem(at: noteURL)
        }
        controller.show(focus: false)
        let snapshot = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: restoreFrame,
            visibleScreenFrame: visibleFrame,
            availableScreenFrames: [visibleFrame, rightNeighbor]
        )

        dock.setStashed(true)
        controller.showStashed(snapshot: snapshot, animated: false)

        #expect(snapshot.parkedFrame.size == restoreFrame.size)
        #expect(controller.window?.frame == snapshot.parkedFrame)
        #expect(controller.window?.frame.size == restoreFrame.size)
        #expect(controller.window?.contentView?.superview?.layer?.mask == nil)
        #expect(controller.window?.isVisible == false)
        let presentationWindow = try #require(NSApp.windows.first {
            $0.identifier?.rawValue
                == "cmux.workspace.float.parkingPresentation.\(dock.id.uuidString)"
        })
        #expect(presentationWindow.frame == snapshot.restingVisibleFrame)
        #expect(presentationWindow.isVisible)
        #expect(presentationWindow.parent == nil)
        #expect(!presentationWindow.styleMask.contains(.nonactivatingPanel))
        #expect(presentationWindow.isExcludedFromWindowsMenu)
        #expect(presentationWindow.collectionBehavior.contains(.ignoresCycle))
        #expect(
            presentationWindow.contentView?.identifier?.rawValue
                == "FloatingWindowParkingPresentation.\(dock.id.uuidString)"
        )
        #expect(controller.window?.ignoresMouseEvents == true)
        #expect(dock.screenFrame == restoreFrame)
    }
}

@Suite(.serialized)
@MainActor
struct WorkspaceFloatingDockNamingAndOrderingTests {
    @Test
    func parkingAccessoryAppearsBesideItsFloatingWindowWithCompactChrome() {
        _ = NSApplication.shared
        let owner = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = WorkspaceFloatingDockParkingAccessoryController(
            dockID: UUID(),
            onRestore: {},
            onRename: { _ in true },
            onDrag: { _, _ in },
            onEditingEnded: {}
        )
        defer {
            controller.teardown()
            owner.close()
        }
        let floatingWindowFrame = CGRect(x: 420, y: 180, width: 520, height: 380)
        owner.setFrame(floatingWindowFrame, display: false)

        controller.show(
            attachedTo: owner,
            title: "Build Notes",
            appearance: .raycast(backgroundColor: .windowBackgroundColor),
            animated: false
        )

        #expect(
            controller.window.frame.maxX
                == owner.frame.minX - WorkspaceFloatingDockParkingAccessoryController.gap
        )
        #expect(controller.window.frame.midY == owner.frame.midY)
        #expect(controller.window.frame.height == 32)
        #expect(controller.window.frame.width < 170)
    }

    @Test
    func parkingAccessoryStaysBesideLiveOwnerWhenRenameChangesItsWidth() async {
        _ = NSApplication.shared
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let initialOwnerFrame = CGRect(
            x: visibleFrame.midX - 80,
            y: visibleFrame.midY - 190,
            width: 520,
            height: 380
        )
        let owner = NSWindow(
            contentRect: initialOwnerFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = WorkspaceFloatingDockParkingAccessoryController(
            dockID: UUID(),
            onRestore: {},
            onRename: { _ in true },
            onDrag: { _, _ in },
            onEditingEnded: {}
        )
        defer {
            controller.teardown()
            owner.orderOut(nil)
            owner.close()
        }

        owner.orderFront(nil)
        controller.show(
            attachedTo: owner,
            title: "Build Notes",
            appearance: .raycast(backgroundColor: .windowBackgroundColor),
            animated: false
        )
        owner.setFrame(
            owner.frame.offsetBy(dx: -120, dy: 64),
            display: true
        )

        controller.beginRenaming()
        try? await Task.sleep(nanoseconds: 250_000_000)

        #expect(
            controller.window.frame.maxX
                == owner.frame.minX - WorkspaceFloatingDockParkingAccessoryController.gap
        )
        #expect(controller.window.frame.midY == owner.frame.midY)

        var resizedOwnerFrame = owner.frame
        resizedOwnerFrame.size.height += 80
        owner.setFrame(resizedOwnerFrame, display: true)
        await Task.yield()

        #expect(
            controller.window.frame.maxX
                == owner.frame.minX - WorkspaceFloatingDockParkingAccessoryController.gap
        )
        #expect(controller.window.frame.midY == owner.frame.midY)
    }

    @Test
    func parkingAccessoryAnimationKeepsEverySampleAttachedToOwner() async {
        _ = NSApplication.shared
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let owner = NSWindow(
            contentRect: CGRect(
                x: visibleFrame.midX,
                y: visibleFrame.midY - 190,
                width: 520,
                height: 380
            ),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = WorkspaceFloatingDockParkingAccessoryController(
            dockID: UUID(),
            onRestore: {},
            onRename: { _ in true },
            onDrag: { _, _ in },
            onEditingEnded: {}
        )
        defer {
            controller.teardown()
            owner.orderOut(nil)
            owner.close()
        }

        owner.orderFront(nil)
        controller.show(
            attachedTo: owner,
            title: "Build Notes",
            appearance: .raycast(backgroundColor: .windowBackgroundColor),
            animated: true
        )

        var maximumGapError: CGFloat = 0
        var maximumCenterError: CGFloat = 0
        for _ in 0..<24 {
            maximumGapError = max(
                maximumGapError,
                abs(
                    controller.window.frame.maxX
                        - (owner.frame.minX - WorkspaceFloatingDockParkingAccessoryController.gap)
                )
            )
            maximumCenterError = max(
                maximumCenterError,
                abs(controller.window.frame.midY - owner.frame.midY)
            )
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        controller.hide(animated: true)
        for _ in 0..<18 {
            maximumGapError = max(
                maximumGapError,
                abs(
                    controller.window.frame.maxX
                        - (owner.frame.minX - WorkspaceFloatingDockParkingAccessoryController.gap)
                )
            )
            maximumCenterError = max(
                maximumCenterError,
                abs(controller.window.frame.midY - owner.frame.midY)
            )
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(maximumGapError < 1)
        #expect(maximumCenterError < 1)
    }

    @Test
    func doubleClickingParkingAccessoryBeginsRenameWithoutRestoring() throws {
        _ = NSApplication.shared
        let noteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-floating-parking-double-click-\(UUID().uuidString).md")
        try "".write(to: noteURL, atomically: true, encoding: .utf8)
        let parent = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceFloatingDock(
            id: UUID(),
            workspaceId: UUID(),
            title: "Rename Me",
            frame: CGRect(x: 200, y: 100, width: 520, height: 380),
            noteFilePath: noteURL.path,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        var restoreRequestCount = 0
        let controller = WorkspaceFloatingDockWindowController(
            dock: dock,
            parentWindow: parent,
            onCloseRequest: { _ in },
            onRestoreRequest: { _ in
                restoreRequestCount += 1
                dock.setStashed(false)
            }
        )
        defer {
            controller.teardown()
            dock.close()
            parent.close()
            try? FileManager.default.removeItem(at: noteURL)
        }
        parent.makeKeyAndOrderFront(nil)
        controller.show(focus: false)
        let restoreFrame = try #require(controller.window?.frame)
        let snapshot = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: restoreFrame,
            visibleScreenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        dock.setStashed(true)
        controller.showStashed(snapshot: snapshot, animated: false)
        controller.setParkingRevealed(true, animated: false)

        let accessoryWindow = try #require(NSApp.windows.first {
            $0.identifier?.rawValue
                == "cmux.workspace.float.parkingAccessory.\(dock.id.uuidString)"
        })
        accessoryWindow.displayIfNeeded()
        accessoryWindow.contentView?.layoutSubtreeIfNeeded()
        let handle = try #require(Self.descendant(
            in: accessoryWindow.contentView,
            accessibilityIdentifier: "FloatingWindowParkingDragHandle.\(dock.id.uuidString)"
        ))
        let location = handle.convert(
            CGPoint(x: handle.bounds.midX, y: handle.bounds.midY),
            to: nil
        )

        handle.mouseDown(with: try Self.mouseEvent(
            type: .leftMouseDown,
            location: location,
            window: accessoryWindow,
            clickCount: 1
        ))
        handle.mouseUp(with: try Self.mouseEvent(
            type: .leftMouseUp,
            location: location,
            window: accessoryWindow,
            clickCount: 1
        ))
        #expect(dock.isStashed)
        #expect(restoreRequestCount == 0)

        handle.mouseDown(with: try Self.mouseEvent(
            type: .leftMouseDown,
            location: location,
            window: accessoryWindow,
            clickCount: 2
        ))
        let renameField = Self.descendant(
            in: accessoryWindow.contentView,
            accessibilityIdentifier: "FloatingWindowRenameField.\(dock.id.uuidString)"
        )
        #expect(dock.isStashed)
        #expect(restoreRequestCount == 0)
        #expect(renameField?.isHidden == false)
        #expect(accessoryWindow.isKeyWindow)
    }

    @Test
    func draggingParkingAccessoryPullsOutAndMovesTheRealFloatingWindow() throws {
        _ = NSApplication.shared
        let noteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-floating-parking-drag-\(UUID().uuidString).md")
        try "".write(to: noteURL, atomically: true, encoding: .utf8)
        let parent = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceFloatingDock(
            id: UUID(),
            workspaceId: UUID(),
            title: "Movable Notes",
            frame: CGRect(x: 200, y: 100, width: 520, height: 380),
            noteFilePath: noteURL.path,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        let controller = WorkspaceFloatingDockWindowController(
            dock: dock,
            parentWindow: parent,
            onCloseRequest: { _ in },
            onRestoreRequest: { _ in dock.setStashed(false) }
        )
        defer {
            controller.teardown()
            dock.close()
            parent.close()
            try? FileManager.default.removeItem(at: noteURL)
        }
        parent.makeKeyAndOrderFront(nil)
        controller.show(focus: false)
        let restoreFrame = try #require(controller.window?.frame)
        let snapshot = WorkspaceFloatingDockParkingSnapshot(
            restoreFrame: restoreFrame,
            visibleScreenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        dock.setStashed(true)
        controller.showStashed(snapshot: snapshot, animated: false)
        controller.setParkingRevealed(true, animated: false)

        let accessoryWindow = try #require(NSApp.windows.first {
            $0.identifier?.rawValue
                == "cmux.workspace.float.parkingAccessory.\(dock.id.uuidString)"
        })
        accessoryWindow.displayIfNeeded()
        accessoryWindow.contentView?.layoutSubtreeIfNeeded()
        let handle = try #require(Self.descendant(
            in: accessoryWindow.contentView,
            accessibilityIdentifier: "FloatingWindowParkingDragHandle.\(dock.id.uuidString)"
        ))
        let initialPanelFrame = try #require(controller.window?.frame)
        let downLocation = handle.convert(
            CGPoint(x: handle.bounds.midX, y: handle.bounds.midY),
            to: nil
        )
        let dragDelta = CGVector(dx: -140, dy: 36)
        let draggedLocation = CGPoint(
            x: downLocation.x + dragDelta.dx,
            y: downLocation.y + dragDelta.dy
        )

        handle.mouseDown(with: try Self.mouseEvent(
            type: .leftMouseDown,
            location: downLocation,
            window: accessoryWindow
        ))
        handle.mouseDragged(with: try Self.mouseEvent(
            type: .leftMouseDragged,
            location: draggedLocation,
            window: accessoryWindow
        ))
        handle.mouseUp(with: try Self.mouseEvent(
            type: .leftMouseUp,
            location: draggedLocation,
            window: accessoryWindow
        ))

        let movedPanelFrame = try #require(controller.window?.frame)
        #expect(!dock.isStashed)
        #expect(movedPanelFrame.minX == initialPanelFrame.minX + dragDelta.dx)
        #expect(movedPanelFrame.minY == initialPanelFrame.minY + dragDelta.dy)
    }

    @Test
    func renameAccessoryUsesStableKeyableChildPanelLifecycle() {
        let controller = WorkspaceFloatingDockParkingAccessoryController(
            dockID: UUID(),
            onRestore: {},
            onRename: { _ in true },
            onDrag: { _, _ in },
            onEditingEnded: {}
        )
        defer { controller.teardown() }

        #expect(!controller.window.isFloatingPanel)
        #expect(controller.window.canBecomeKey)
        #expect(!controller.window.canBecomeMain)
    }

    @Test
    func renameAccessoryKeepsEditingAcrossTheDeferredFocusTurn() async throws {
        _ = NSApplication.shared
        let owner = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = WorkspaceFloatingDockParkingAccessoryController(
            dockID: UUID(),
            onRestore: {},
            onRename: { _ in true },
            onDrag: { _, _ in },
            onEditingEnded: {}
        )
        defer {
            controller.teardown()
            owner.orderOut(nil)
            owner.close()
        }

        owner.makeKeyAndOrderFront(nil)
        controller.show(
            attachedTo: owner,
            title: "Build Notes",
            appearance: .raycast(backgroundColor: .windowBackgroundColor),
            animated: false
        )
        controller.beginRenaming()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(controller.isEditing)
        #expect(controller.window.isKeyWindow)
    }

    @Test
    func renameValidationAndVisualReorderSharePersistedDockMetadata() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let docks = (0..<3).map { index in
            WorkspaceFloatingDock(
                id: UUID(),
                workspaceId: workspace.id,
                title: ["Alpha", "Beta", "Gamma"][index],
                frame: CGRect(x: 40, y: 40, width: 520, height: 380),
                noteFilePath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-order-\(UUID().uuidString).md")
                    .path,
                presentationState: .stashed,
                stashedAt: TimeInterval(index + 1),
                initialContent: nil,
                baseDirectoryProvider: { nil },
                remoteBrowserSettingsProvider: { .local }
            )
        }
        workspace.floatingDocks.append(contentsOf: docks)
        defer {
            workspace.floatingDocks.removeAll { dock in
                docks.contains { $0 === dock }
            }
            docks.forEach { $0.close() }
        }

        #expect(workspace.stashedFloatingDocksInVisualOrder.map(\.title) == [
            "Gamma", "Beta", "Alpha",
        ])
        #expect(docks[0].rename(to: "  Release Notes  "))
        #expect(docks[0].title == "Release Notes")
        #expect(!docks[0].rename(to: "   "))
        #expect(!docks[0].rename(to: String(repeating: "x", count: 121)))

        #expect(workspace.reorderStashedFloatingDock(
            id: docks[0].id,
            toVisualPosition: 1,
            timestamp: 10
        ))
        #expect(workspace.stashedFloatingDocksInVisualOrder.map(\.title) == [
            "Release Notes", "Gamma", "Beta",
        ])
        #expect(workspace.stashedFloatingDockVisualPosition(id: docks[0].id) == 1)
        #expect(docks.map(\.isStashed) == [true, true, true])
    }

    private static func descendant(
        in root: NSView?,
        accessibilityIdentifier: String
    ) -> NSView? {
        guard let root else { return nil }
        if root.accessibilityIdentifier() == accessibilityIdentifier {
            return root
        }
        for subview in root.subviews {
            if let match = descendant(
                in: subview,
                accessibilityIdentifier: accessibilityIdentifier
            ) {
                return match
            }
        }
        return nil
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }
}

@Suite(.serialized)
@MainActor
struct WorkspaceFloatingDockKeyContextTests {
    @Test
    func floatingWindowsFollowTheirOwningKeyWindowContext() throws {
        _ = NSApplication.shared
        let noteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-floating-key-context-\(UUID().uuidString).md")
        try "".write(to: noteURL, atomically: true, encoding: .utf8)

        let parent = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let unrelatedWindow = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let transient = NSPanel(
            contentRect: CGRect(x: 250, y: 250, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let dock = WorkspaceFloatingDock(
            id: UUID(),
            workspaceId: workspace.id,
            title: "Key context",
            frame: CGRect(x: 40, y: 40, width: 520, height: 380),
            noteFilePath: noteURL.path,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        workspace.floatingDocks.append(dock)
        let presenter = WorkspaceFloatingDockPresenter(
            parentWindow: parent,
            tabManager: manager
        )
        defer {
            presenter.teardown()
            workspace.floatingDocks.removeAll { $0 === dock }
            dock.close()
            if transient.parent === parent {
                parent.removeChildWindow(transient)
            }
            transient.close()
            unrelatedWindow.close()
            parent.close()
            try? FileManager.default.removeItem(at: noteURL)
        }

        presenter.updateKeyContext(keyWindow: nil, applicationIsActive: true)
        presenter.refresh()
        let floatingWindow = try #require(presenter.window(for: dock))
        #expect(!floatingWindow.isVisible)

        presenter.updateKeyContext(keyWindow: parent, applicationIsActive: true)
        #expect(floatingWindow.isVisible)

        parent.addChildWindow(transient, ordered: .above)
        presenter.updateKeyContext(keyWindow: transient, applicationIsActive: true)
        #expect(floatingWindow.isVisible)

        presenter.updateKeyContext(keyWindow: unrelatedWindow, applicationIsActive: true)
        #expect(!floatingWindow.isVisible)

        presenter.updateKeyContext(keyWindow: floatingWindow, applicationIsActive: true)
        #expect(floatingWindow.isVisible)

        presenter.updateKeyContext(keyWindow: nil, applicationIsActive: false)
        #expect(!floatingWindow.isVisible)
    }

    @Test
    func parkedRenameAccessoryUsesItsFloatingWindowAsItsKeyContextOwner() throws {
        _ = NSApplication.shared
        let noteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-floating-rename-owner-\(UUID().uuidString).md")
        try "".write(to: noteURL, atomically: true, encoding: .utf8)

        let parent = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let dock = WorkspaceFloatingDock(
            id: UUID(),
            workspaceId: workspace.id,
            title: "Release Notes",
            frame: CGRect(x: 40, y: 40, width: 520, height: 380),
            noteFilePath: noteURL.path,
            presentationState: .stashed,
            stashedAt: 1,
            baseDirectoryProvider: { nil },
            remoteBrowserSettingsProvider: { .local }
        )
        workspace.floatingDocks.append(dock)
        let presenter = WorkspaceFloatingDockPresenter(
            parentWindow: parent,
            tabManager: manager
        )
        defer {
            presenter.teardown()
            workspace.floatingDocks.removeAll { $0 === dock }
            dock.close()
            parent.close()
            try? FileManager.default.removeItem(at: noteURL)
        }

        presenter.updateKeyContext(keyWindow: parent, applicationIsActive: true)
        presenter.refresh()
        let floatingWindow = try #require(presenter.window(for: dock))
        presenter.beginRenaming(dock)

        let accessory = (floatingWindow.childWindows ?? []).first { window in
            window.identifier?.rawValue.hasPrefix(
                "cmux.workspace.float.parkingAccessory."
            ) == true
        }
        #expect(accessory != nil)
        #expect(accessory?.parent === floatingWindow)
        #expect(accessory?.parent !== parent)
    }
}
