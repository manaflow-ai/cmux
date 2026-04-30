import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WindowGlassEffectTests: XCTestCase {
    func testRemoveRestoresOriginalContentHierarchy() {
        _ = NSApplication.shared

        let originalContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: originalContentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = originalContentView

        WindowGlassEffect.apply(to: window, tintColor: .systemBlue)

        if WindowGlassEffect.isAvailable {
            XCTAssertFalse(window.contentView === originalContentView)
            XCTAssertTrue(WindowGlassEffect.originalContentView(for: window) === originalContentView)
            XCTAssertTrue(originalContentView.superview === WindowGlassEffect.foregroundContainer(for: window))
            XCTAssertNotNil(WindowGlassEffect.portalInstallationTarget(for: window))
        } else {
            XCTAssertTrue(window.contentView === originalContentView)
            XCTAssertNil(WindowGlassEffect.originalContentView(for: window))
            XCTAssertNil(WindowGlassEffect.foregroundContainer(for: window))
            XCTAssertNil(WindowGlassEffect.portalInstallationTarget(for: window))
        }
        XCTAssertTrue(Self.windowContainsGlassBackground(window))

        WindowGlassEffect.remove(from: window)

        XCTAssertTrue(window.contentView === originalContentView)
        XCTAssertNil(WindowGlassEffect.foregroundContainer(for: window))
        XCTAssertNil(WindowGlassEffect.originalContentView(for: window))
        XCTAssertFalse(Self.windowContainsGlassBackground(window))
    }

    func testNativeGlassTintFollowsWindowKeyNotifications() throws {
        guard WindowGlassEffect.isAvailable else {
            throw XCTSkip("NSGlassEffectView is unavailable on this macOS version")
        }
        _ = NSApplication.shared

        let originalContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: originalContentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = originalContentView

        WindowGlassEffect.apply(to: window, tintColor: .black, style: .clear)

        guard let backgroundView = Self.glassBackgroundView(in: window.contentView),
              let tintOverlay = backgroundView.subviews.last else {
            XCTFail("Expected glass background tint overlay")
            return
        }

        XCTAssertGreaterThan(tintOverlay.alphaValue, 0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(tintOverlay.alphaValue, 0, accuracy: 0.001)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertGreaterThan(tintOverlay.alphaValue, 0)
    }

    private static func windowContainsGlassBackground(_ window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        let root = contentView.superview ?? contentView
        return glassBackgroundView(in: root) != nil
    }

    private static func glassBackgroundView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier == WindowGlassEffect.backgroundViewIdentifier {
            return view
        }
        return view.subviews.lazy.compactMap(glassBackgroundView(in:)).first
    }
}

@MainActor
final class WindowAccessorTests: XCTestCase {
    func testSameWindowDedupeAllowsRefreshIDChanges() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()

        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-off"))
        XCTAssertFalse(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-off"))
        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-clear"))
        XCTAssertFalse(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-clear"))
    }

    func testDedupeDisabledAlwaysInvokesForSameWindow() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()

        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: false, refreshID: "same"))
        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: false, refreshID: "same"))
    }
}

@MainActor
final class AppDelegateWindowContextRoutingTests: XCTestCase {
    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    func testSynchronizeActiveMainWindowContextPrefersProvidedWindowOverStaleActiveManager() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        windowB.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowB)
        XCTAssertTrue(app.tabManager === managerB)

        windowA.makeKeyAndOrderFront(nil)
        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(resolved === managerA, "Expected provided active window to win over stale active manager")
        XCTAssertTrue(app.tabManager === managerA)
    }

    func testSynchronizeActiveMainWindowContextFallsBackToActiveManagerWithoutFocusedWindow() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        // Seed active manager and clear focus windows to force fallback routing.
        windowA.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(app.tabManager === managerA)
        windowA.orderOut(nil)
        windowB.orderOut(nil)

        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: nil)
        XCTAssertTrue(resolved === managerA, "Expected fallback to preserve current active manager instead of arbitrary window")
        XCTAssertTrue(app.tabManager === managerA)
    }

    func testSynchronizeActiveMainWindowContextUsesRegisteredWindowEvenIfIdentifierMutates() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        // SwiftUI can replace the NSWindow identifier string at runtime.
        window.identifier = NSUserInterfaceItemIdentifier("SwiftUI.AppWindow.IdentifierChanged")

        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: window)
        XCTAssertTrue(resolved === manager, "Expected registered window object identity to win even if identifier string changed")
        XCTAssertTrue(app.tabManager === manager)
    }

    func testAddWorkspaceWithoutBringToFrontPreservesActiveWindowAndSelection() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        windowA.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(app.tabManager === managerA)

        let originalSelectedA = managerA.selectedTabId
        let originalSelectedB = managerB.selectedTabId
        let originalTabCountB = managerB.tabs.count

        let createdWorkspaceId = app.addWorkspace(windowId: windowBId, bringToFront: false)

        XCTAssertNotNil(createdWorkspaceId)
        XCTAssertTrue(app.tabManager === managerA, "Expected non-focus workspace creation to preserve active window routing")
        XCTAssertEqual(managerA.selectedTabId, originalSelectedA)
        XCTAssertEqual(managerB.selectedTabId, originalSelectedB, "Expected background workspace creation to preserve selected tab")
        XCTAssertEqual(managerB.tabs.count, originalTabCountB + 1)
        XCTAssertTrue(managerB.tabs.contains(where: { $0.id == createdWorkspaceId }))
    }

    func testApplicationOpenURLsAddsWorkspaceForDroppedFolderURL() throws {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        window.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: window)

        let defaults = UserDefaults.standard
        let previousWelcomeShown = defaults.object(forKey: WelcomeSettings.shownKey)
        defaults.set(true, forKey: WelcomeSettings.shownKey)
        defer {
            if let previousWelcomeShown {
                defaults.set(previousWelcomeShown, forKey: WelcomeSettings.shownKey)
            } else {
                defaults.removeObject(forKey: WelcomeSettings.shownKey)
            }
        }

        let rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let droppedDirectory = rootDirectory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: droppedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let existingWorkspaceIds = Set(manager.tabs.map(\.id))

        app.application(
            NSApplication.shared,
            open: [URL(fileURLWithPath: droppedDirectory.path)]
        )

        let createdWorkspace = manager.tabs.first { !existingWorkspaceIds.contains($0.id) }
        XCTAssertNotNil(createdWorkspace)
        XCTAssertEqual(createdWorkspace?.currentDirectory, droppedDirectory.path)
    }

    func testApplicationOpenURLsIgnoresBundleSelfPaths() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        window.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: window)

        let existingWorkspaceIds = Set(manager.tabs.map(\.id))
        let embeddedExecutableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/cmux", isDirectory: false)

        app.application(
            NSApplication.shared,
            open: [embeddedExecutableURL]
        )

        let createdWorkspace = manager.tabs.first { !existingWorkspaceIds.contains($0.id) }
        XCTAssertNil(createdWorkspace)
    }
}


@MainActor
final class AppDelegateLaunchServicesRegistrationTests: XCTestCase {
    func testScheduleLaunchServicesRegistrationDefersRegisterWork() {
        _ = NSApplication.shared
        let app = AppDelegate()

        var scheduledWork: (@Sendable () -> Void)?
        var registerCallCount = 0

        app.scheduleLaunchServicesBundleRegistrationForTesting(
            bundleURL: URL(fileURLWithPath: "/tmp/../tmp/cmux-launch-services-test.app"),
            scheduler: { work in
                scheduledWork = work
            },
            register: { _ in
                registerCallCount += 1
                return noErr
            }
        )

        XCTAssertEqual(registerCallCount, 0, "Registration should not run inline on the startup call path")
        XCTAssertNotNil(scheduledWork, "Registration work should be handed to the scheduler")

        scheduledWork?()

        XCTAssertEqual(registerCallCount, 1)
    }
}


final class FocusFlashPatternTests: XCTestCase {
    func testFocusFlashPatternMatchesTerminalDoublePulseShape() {
        XCTAssertEqual(FocusFlashPattern.values, [0, 1, 0, 1, 0])
        XCTAssertEqual(FocusFlashPattern.keyTimes, [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(FocusFlashPattern.duration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.curves, [.easeOut, .easeIn, .easeOut, .easeIn])
        XCTAssertEqual(FocusFlashPattern.ringInset, 6, accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.ringCornerRadius, 10, accuracy: 0.0001)
    }

    func testFocusFlashPatternSegmentsCoverFullDoublePulseTimeline() {
        let segments = FocusFlashPattern.segments
        XCTAssertEqual(segments.count, 4)

        XCTAssertEqual(segments[0].delay, 0.0, accuracy: 0.0001)
        XCTAssertEqual(segments[0].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[0].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[0].curve, .easeOut)

        XCTAssertEqual(segments[1].delay, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[1].curve, .easeIn)

        XCTAssertEqual(segments[2].delay, 0.45, accuracy: 0.0001)
        XCTAssertEqual(segments[2].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[2].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[2].curve, .easeOut)

        XCTAssertEqual(segments[3].delay, 0.675, accuracy: 0.0001)
        XCTAssertEqual(segments[3].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[3].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[3].curve, .easeIn)
    }
}


@available(macOS 26.0, *)
private struct DragConfigurationOperationsSnapshot: Equatable {
    let allowCopy: Bool
    let allowMove: Bool
    let allowDelete: Bool
    let allowAlias: Bool
}

@available(macOS 26.0, *)
private enum DragConfigurationSnapshotError: Error {
    case missingBoolField(primary: String, fallback: String?)
}

@available(macOS 26.0, *)
private func dragConfigurationOperationsSnapshot<T>(from operations: T) throws -> DragConfigurationOperationsSnapshot {
    let mirror = Mirror(reflecting: operations)

    func readBool(_ primary: String, fallback: String? = nil) throws -> Bool {
        if let value = mirror.descendant(primary) as? Bool {
            return value
        }
        if let fallback, let value = mirror.descendant(fallback) as? Bool {
            return value
        }
        throw DragConfigurationSnapshotError.missingBoolField(primary: primary, fallback: fallback)
    }

    return try DragConfigurationOperationsSnapshot(
        allowCopy: readBool("allowCopy", fallback: "_allowCopy"),
        allowMove: readBool("allowMove", fallback: "_allowMove"),
        allowDelete: readBool("allowDelete", fallback: "_allowDelete"),
        allowAlias: readBool("allowAlias", fallback: "_allowAlias")
    )
}

#if compiler(>=6.2)
@MainActor
final class InternalTabDragConfigurationTests: XCTestCase {
    func testDisablesExternalOperationsForInternalTabDrags() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Requires macOS 26 drag configuration APIs")
        }

        let configuration = InternalTabDragConfigurationProvider.value
        let withinApp = try dragConfigurationOperationsSnapshot(from: configuration.operationsWithinApp)
        let outsideApp = try dragConfigurationOperationsSnapshot(from: configuration.operationsOutsideApp)

        XCTAssertEqual(
            withinApp,
            DragConfigurationOperationsSnapshot(
                allowCopy: false,
                allowMove: true,
                allowDelete: false,
                allowAlias: false
            )
        )

        XCTAssertEqual(
            outsideApp,
            DragConfigurationOperationsSnapshot(
                allowCopy: false,
                allowMove: false,
                allowDelete: false,
                allowAlias: false
            )
        )
    }
}


@MainActor
final class InternalTabDragBundleDeclarationTests: XCTestCase {
    private func exportedTypeIdentifiers(bundle: Bundle) -> Set<String> {
        let declarations = (bundle.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]) ?? []
        return Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
    }

    func testAppBundleExportsInternalDragTypes() {
        let exported = exportedTypeIdentifiers(bundle: Bundle(for: AppDelegate.self))

        XCTAssertTrue(
            exported.contains("com.splittabbar.tabtransfer"),
            "Expected app bundle to export bonsplit tab-transfer type, got \(exported)"
        )
        XCTAssertTrue(
            exported.contains("com.cmux.sidebar-tab-reorder"),
            "Expected app bundle to export sidebar tab-reorder type, got \(exported)"
        )
    }
}
#endif


@MainActor
final class WindowDragHandleHitTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class HostContainerView: NSView {}
    private final class BlockingTopHitContainerView: NSView {
        var hitCount = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            hitCount += 1
            return bounds.contains(point) ? self : nil
        }
    }
    private final class PassThroughProbeView: NSView {
        var onHitTest: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            onHitTest?()
            return nil
        }
    }
    private final class PassiveHostContainerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            return super.hitTest(point) ?? self
        }
    }

    private final class SidebarActionRegionView: NSView, MinimalModeSidebarControlActionHitRegionProviding {
        nonisolated(unsafe) var config = TitlebarControlsStyle.classic.config

        nonisolated func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool {
            minimalModeSidebarControlActionSlot(localPoint: localPoint) != nil
        }

        nonisolated func minimalModeSidebarControlActionSlot(localPoint: NSPoint) -> MinimalModeSidebarControlActionSlot? {
            let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)
            for (index, range) in ranges.enumerated() where range.contains(localPoint.x) {
                return MinimalModeSidebarControlActionSlot(rawValue: index)
            }
            return nil
        }
    }

    private final class MutatingSiblingView: NSView {
        weak var container: NSView?
        private var didMutate = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            guard !didMutate, let container else { return nil }
            didMutate = true
            let transient = NSView(frame: .zero)
            container.addSubview(transient)
            transient.removeFromSuperview()
            return nil
        }
    }

    private final class ReentrantDragHandleView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let shouldCapture = windowDragHandleShouldCaptureHit(point, in: self, eventType: .leftMouseDown, eventWindow: self.window)
            return shouldCapture ? self : nil
        }
    }

    /// A sibling view whose hitTest re-enters windowDragHandleShouldCaptureHit,
    /// simulating the crash path where sibling.hitTest triggers a SwiftUI layout
    /// pass that calls back into the drag handle's hit resolution.
    private final class ReentrantSiblingView: NSView {
        weak var dragHandle: NSView?
        var reenteredResult: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point), let dragHandle else { return nil }
            // Simulate the re-entry: during sibling hit test, SwiftUI layout
            // calls windowDragHandleShouldCaptureHit on the drag handle again.
            reenteredResult = windowDragHandleShouldCaptureHit(
                point, in: dragHandle, eventType: .leftMouseDown, eventWindow: dragHandle.window
            )
            return nil
        }
    }

    func testDragHandleCapturesHitWhenNoSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Empty titlebar space should drag the window"
        )
    }

    func testDragHandleYieldsWhenSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let folderIconHost = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        container.addSubview(folderIconHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown),
            "Interactive titlebar controls should receive the mouse event"
        )
        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown))
    }

    func testTitlebarControlGapsAreOutsideButtonHitColumns() {
        let config = TitlebarControlsStyle.classic.config
        let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)
        XCTAssertEqual(ranges.count, 3)

        XCTAssertTrue(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(
                NSPoint(x: ranges[0].lowerBound + 1, y: 14),
                config: config
            ),
            "Icon button columns should stay interactive"
        )

        let firstGapX = (ranges[0].upperBound + ranges[1].lowerBound) / 2
        let secondGapX = (ranges[1].upperBound + ranges[2].lowerBound) / 2

        XCTAssertFalse(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(NSPoint(x: firstGapX, y: 14), config: config),
            "The gap between the sidebar and notification icons should remain available for window dragging"
        )
        XCTAssertFalse(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(NSPoint(x: secondGapX, y: 14), config: config),
            "The gap between the notification and new-workspace icons should remain available for window dragging"
        )
    }

    func testDragHandleIgnoresHiddenSiblingWhenResolvingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let hidden = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        hidden.isHidden = true
        container.addSubview(hidden)

        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleDoesNotCaptureOutsideBounds() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertFalse(windowDragHandleShouldCaptureHit(NSPoint(x: 240, y: 18), in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleSkipsCaptureForPassivePointerEvents() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let point = NSPoint(x: 180, y: 18)
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .mouseMoved))
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .cursorUpdate))
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: nil))
        XCTAssertTrue(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleSkipsForeignLeftMouseDownDuringLaunch() {
        let point = NSPoint(x: 180, y: 18)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let dragHandle = NSView(frame: container.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        container.addSubview(dragHandle)

        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { foreignWindow.orderOut(nil) }

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: nil
            ),
            "Launch activation events without a matching window should not trigger drag-handle hierarchy walk"
        )

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: foreignWindow
            ),
            "Left mouse-down events for a different window should be treated as passive"
        )

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Left mouse-down events for this window should still capture empty titlebar space"
        )
    }

    func testPassiveHostingTopHitClassification() {
        XCTAssertTrue(windowDragHandleShouldTreatTopHitAsPassiveHost(HostContainerView(frame: .zero)))
        XCTAssertFalse(windowDragHandleShouldTreatTopHitAsPassiveHost(NSButton(frame: .zero)))
    }

    func testMinimalModeTitlebarControlRegionRegistryMatchesVisibleRegisteredView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = NSView(frame: NSRect(x: 72, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        XCTAssertTrue(isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 100, y: 100)))
        XCTAssertFalse(isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 20, y: 100)))

        controlRegion.isHidden = true
        XCTAssertFalse(isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 100, y: 100)))
    }

    func testMinimalModeTitlebarControlRegionCanLimitHitsInsideRegisteredView() {
        final class ButtonOnlyRegion: NSView, MinimalModeTitlebarControlHitRegionProviding {
            nonisolated func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool {
                localPoint.x >= 24 && localPoint.x <= 48
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = ButtonOnlyRegion(frame: NSRect(x: 72, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        XCTAssertTrue(
            isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 100, y: 100)),
            "Expected points inside the provider's button range to suppress titlebar double-click handling."
        )
        XCTAssertFalse(
            isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 136, y: 100)),
            "Expected gaps inside the registered view to keep behaving like titlebar chrome."
        )
    }

    func testMinimalModeSidebarActionSlotUsesRegisteredHostFrame() {
        let suiteName = "WindowDragHandleHitTests.sidebarHostFrame.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: "titlebarControlsStyle")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = SidebarActionRegionView(frame: NSRect(x: 88, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        XCTAssertEqual(
            minimalModeSidebarControlActionSlot(
                window: window,
                locationInWindow: NSPoint(x: controlRegion.frame.minX + 50, y: controlRegion.frame.minY + 14),
                defaults: defaults
            ),
            .showNotifications,
            "Sidebar control actions should use the actual registered host frame instead of a fixed window x origin."
        )
    }

    func testMinimalModeSidebarActionSlotUsesRegisteredHostFrameBelowFallbackBand() {
        let suiteName = "WindowDragHandleHitTests.sidebarHostFrameBand.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: "titlebarControlsStyle")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = SidebarActionRegionView(frame: NSRect(x: 88, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        let point = NSPoint(x: controlRegion.frame.minX + 14, y: controlRegion.frame.minY + 1)
        XCTAssertFalse(
            isPointInMinimalModeTitlebarBand(
                isEnabled: true,
                point: point,
                bounds: contentView.bounds,
                topStripHeight: MinimalModeChromeMetrics.titlebarHeight
            ),
            "The regression point should sit inside the visual control host but outside the hard-coded fallback band."
        )
        XCTAssertEqual(
            minimalModeSidebarControlActionSlot(window: window, locationInWindow: point, defaults: defaults),
            .toggleSidebar
        )
        XCTAssertTrue(
            isMinimalModeSidebarChromeHoverCandidate(window: window, locationInWindow: point, defaults: defaults),
            "Hover reveal should follow the real control host frame."
        )
    }

    func testSuppressedTitlebarDoubleClickConsumesWithoutWindowAction() {
        XCTAssertEqual(
            handleTitlebarDoubleClick(window: nil, behavior: .suppress),
            .suppressed
        )
        XCTAssertEqual(
            handleTitlebarDoubleClick(window: nil, behavior: .standardAction),
            .ignored
        )
        XCTAssertTrue(TitlebarDoubleClickHandlingResult.suppressed.consumesEvent)
        XCTAssertFalse(TitlebarDoubleClickHandlingResult.ignored.consumesEvent)
    }

    func testMinimalModeDoubleClickHandlerOnlyHandlesTopStripDoubleClicks() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 2,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 2,
                point: NSPoint(x: 200, y: 240),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: false,
                clickCount: 2,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 1,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
    }

    func testMinimalModeWindowDoubleClickRequiresMainTopStrip() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: false,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: true,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: false,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 240),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
    }

    func testMinimalModeTitlebarConsecutiveClicksCanFormDoubleClick() {
        let previous = MinimalModeTitlebarClickRecord(
            windowNumber: 42,
            timestamp: 10,
            locationInWindow: NSPoint(x: 200, y: 292)
        )

        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.65,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.62,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5,
                doubleClickIntervalTolerance: 0.15
            )
        )
        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 2,
                timestamp: 20,
                locationInWindow: NSPoint(x: 20, y: 20),
                windowNumber: 99,
                previous: nil,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.8,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 240, y: 292),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 43,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
    }

    func testDragHandleIgnoresPassiveHostSiblingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        container.addSubview(passiveHost)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Passive host wrappers should not block titlebar drag capture"
        )
    }

    func testDragHandleRespectsInteractiveChildInsidePassiveHost() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        let folderControl = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        passiveHost.addSubview(folderControl)
        container.addSubview(passiveHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown),
            "Interactive controls inside passive host wrappers should still receive hits"
        )
    }

    func testTopHitResolutionStateIsScopedPerWindow() {
        let point = NSPoint(x: 100, y: 18)

        let outerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { outerWindow.orderOut(nil) }
        guard let outerContentView = outerWindow.contentView else {
            XCTFail("Expected outer content view")
            return
        }
        let outerContainer = NSView(frame: outerContentView.bounds)
        outerContainer.autoresizingMask = [.width, .height]
        outerContentView.addSubview(outerContainer)
        let outerDragHandle = NSView(frame: outerContainer.bounds)
        outerDragHandle.autoresizingMask = [.width, .height]
        outerContainer.addSubview(outerDragHandle)

        let nestedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { nestedWindow.orderOut(nil) }
        guard let nestedContentView = nestedWindow.contentView else {
            XCTFail("Expected nested content view")
            return
        }
        let nestedContainer = NSView(frame: nestedContentView.bounds)
        nestedContainer.autoresizingMask = [.width, .height]
        nestedContentView.addSubview(nestedContainer)
        let nestedDragHandle = NSView(frame: nestedContainer.bounds)
        nestedDragHandle.autoresizingMask = [.width, .height]
        nestedContainer.addSubview(nestedDragHandle)
        let nestedBlockingOverlay = BlockingTopHitContainerView(frame: nestedContainer.bounds)
        nestedBlockingOverlay.autoresizingMask = [.width, .height]
        nestedContainer.addSubview(nestedBlockingOverlay)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(point, in: nestedDragHandle, eventType: .leftMouseDown, eventWindow: nestedWindow),
            "Nested window drag handle should be blocked by top-hit titlebar container"
        )
        XCTAssertEqual(nestedBlockingOverlay.hitCount, 1)

        var nestedCaptureResult: Bool?
        let probe = PassThroughProbeView(frame: outerContainer.bounds)
        probe.autoresizingMask = [.width, .height]
        probe.onHitTest = {
            nestedCaptureResult = windowDragHandleShouldCaptureHit(point, in: nestedDragHandle, eventType: .leftMouseDown, eventWindow: nestedWindow)
        }
        outerContainer.addSubview(probe)

        _ = windowDragHandleShouldCaptureHit(point, in: outerDragHandle, eventType: .leftMouseDown, eventWindow: outerWindow)

        XCTAssertEqual(
            nestedCaptureResult,
            false,
            "Top-hit recursion in one window must not disable top-hit resolution in another window"
        )
        XCTAssertEqual(
            nestedBlockingOverlay.hitCount,
            2,
            "Nested window should resolve its own blocking sibling while another window is resolving hits"
        )
    }

    func testDragHandleRemainsStableWhenSiblingMutatesSubviewsDuringHitTest() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let mutatingSibling = MutatingSiblingView(frame: container.bounds)
        mutatingSibling.container = container
        container.addSubview(mutatingSibling)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Subview mutations during hit testing should not crash or break drag-handle capture"
        )
    }

    func testDragHandleSiblingHitTestReentrancyDoesNotCrash() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let reentrantSibling = ReentrantSiblingView(frame: container.bounds)
        reentrantSibling.dragHandle = dragHandle
        container.addSubview(reentrantSibling)

        // The outer call enters the sibling walk, which calls
        // reentrantSibling.hitTest(), which re-enters
        // windowDragHandleShouldCaptureHit. Without the re-entrancy guard
        // this would trigger a Swift exclusive-access violation (SIGABRT).
        let outerResult = windowDragHandleShouldCaptureHit(
            NSPoint(x: 110, y: 18), in: dragHandle, eventType: .leftMouseDown
        )
        XCTAssertTrue(outerResult, "Outer call should still capture when sibling returns nil")
        XCTAssertEqual(
            reentrantSibling.reenteredResult, false,
            "Re-entrant call should bail out (return false) instead of crashing"
        )
    }

    func testDragHandleTopHitResolutionSurvivesSameWindowReentrancy() {
        let point = NSPoint(x: 180, y: 18)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let dragHandle = ReentrantDragHandleView(frame: container.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .leftMouseDown, eventWindow: window),
            "Reentrant same-window top-hit resolution should not trigger exclusivity crashes"
        )
    }
}

#if DEBUG


@MainActor
final class DraggableFolderHitTests: XCTestCase {
    func testFolderHitTestReturnsContainerWhenInsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        guard let hit = folderView.hitTest(NSPoint(x: 8, y: 8)) else {
            XCTFail("Expected folder icon to capture inside hit")
            return
        }
        XCTAssertTrue(hit === folderView)
    }

    func testFolderHitTestReturnsNilOutsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        XCTAssertNil(folderView.hitTest(NSPoint(x: 20, y: 8)))
    }

    func testFolderIconDisablesWindowMoveBehavior() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertFalse(folderView.mouseDownCanMoveWindow)
    }
}


@MainActor
final class TitlebarLeadingInsetPassthroughViewTests: XCTestCase {
    func testLeadingInsetViewDoesNotParticipateInHitTesting() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 10)))
    }

    func testLeadingInsetViewCannotMoveWindowViaMouseDown() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }
}


@MainActor
final class FolderWindowMoveSuppressionTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    func testSuppressionDisablesMovableWindow() {
        let window = makeWindow()
        window.isMovable = true

        let previous = temporarilyDisableWindowDragging(window: window)

        XCTAssertEqual(previous, true)
        XCTAssertFalse(window.isMovable)
    }

    func testSuppressionPreservesAlreadyImmovableWindow() {
        let window = makeWindow()
        window.isMovable = false

        let previous = temporarilyDisableWindowDragging(window: window)

        XCTAssertEqual(previous, false)
        XCTAssertFalse(window.isMovable)
    }

    func testRestoreAppliesPreviousMovableState() {
        let window = makeWindow()
        window.isMovable = false

        restoreWindowDragging(window: window, previousMovableState: true)
        XCTAssertTrue(window.isMovable)

        restoreWindowDragging(window: window, previousMovableState: false)
        XCTAssertFalse(window.isMovable)
    }

    func testWindowDragSuppressionDepthLifecycle() {
        let window = makeWindow()
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testWindowDragSuppressionIsReferenceCounted() {
        let window = makeWindow()
        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(beginWindowDragSuppression(window: window), 2)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 2)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testTemporaryWindowMovableEnableRestoresImmovableWindow() {
        let window = makeWindow()
        window.isMovable = false

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, false)
        XCTAssertFalse(window.isMovable)
    }

    func testTemporaryWindowMovableEnablePreservesMovableWindow() {
        let window = makeWindow()
        window.isMovable = true

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, true)
        XCTAssertTrue(window.isMovable)
    }
}


@MainActor
final class WindowMoveSuppressionHitPathTests: XCTestCase {
    private func makeWindowWithContentView() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        return (window, contentView)
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    func testSuppressionHitPathRecognizesFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: folderView))
    }

    func testSuppressionHitPathRecognizesDescendantOfFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        let child = NSView(frame: .zero)
        folderView.addSubview(child)
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: child))
    }

    func testSuppressionHitPathIgnoresUnrelatedViews() {
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: NSView(frame: .zero)))
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: nil))
    }

    func testSuppressionEventPathRecognizesFolderHitInsideWindow() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        contentView.addSubview(folderView)

        let event = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 14, y: 14), window: window)

        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(window: window, event: event))
    }

    func testSuppressionEventPathRejectsNonFolderAndNonMouseDownEvents() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let plainView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        contentView.addSubview(plainView)

        let down = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: down))

        let dragged = makeMouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: dragged))
    }
}

private final class FilePreviewPDFChromeNotificationFlag: @unchecked Sendable {
    var didNotify = false
}


@MainActor
final class FilePreviewPDFChromeTests: XCTestCase {
    func testChromeHostsAcceptFirstMouse() {
        let host = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))

        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
    }

    #if DEBUG
    func testPDFChromeStyleVariantPersistsForDebugWindow() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.string(forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
        let notificationFlag = FilePreviewPDFChromeNotificationFlag()
        let observer = NotificationCenter.default.addObserver(
            forName: .filePreviewPDFChromeStyleDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationFlag.didNotify = true
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            if let previousValue {
                defaults.set(previousValue, forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
            } else {
                defaults.removeObject(forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
            }
        }

        defaults.removeObject(forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
        XCTAssertEqual(FilePreviewPDFChromeStyleVariant.current(), .liquidGlass)

        FilePreviewPDFChromeStyleVariant.thinOutline.persist()
        XCTAssertEqual(FilePreviewPDFChromeStyleVariant.current(), .thinOutline)
        XCTAssertTrue(notificationFlag.didNotify)
    }
    #endif

    func testPDFChromeControlsUseSwiftUILiquidGlassHosts() throws {
        let container = FilePreviewPDFContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let mirror = Mirror(reflecting: container)
        let sidebarChromeHost = try XCTUnwrap(
            mirror.descendant("sidebarChromeHost") as? FilePreviewPDFChromeHostingView
        )
        let zoomChromeHost = try XCTUnwrap(
            mirror.descendant("zoomChromeHost") as? FilePreviewPDFChromeHostingView
        )
        let chromeHost = try XCTUnwrap(
            mirror.descendant("chromeHost") as? FilePreviewPDFChromeHostView
        )

        XCTAssertFalse(sidebarChromeHost.isHidden)
        XCTAssertFalse(zoomChromeHost.isHidden)
        XCTAssertEqual(chromeHost.interactiveOverlayViews.count, 2)
        XCTAssertTrue(chromeHost.interactiveOverlayViews.contains { $0 === sidebarChromeHost })
        XCTAssertTrue(chromeHost.interactiveOverlayViews.contains { $0 === zoomChromeHost })
    }

    func testPDFChromeControlsAreHitTestedAbovePDFContent() throws {
        let container = FilePreviewPDFContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let hostView = NSView(frame: container.frame)
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: hostView.topAnchor),
            container.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
        window.layoutIfNeeded()
        hostView.needsLayout = true
        hostView.layoutSubtreeIfNeeded()
        container.needsLayout = true
        container.layout()
        container.layoutSubtreeIfNeeded()

        let mirror = Mirror(reflecting: container)
        let chromeHost = try XCTUnwrap(mirror.descendant("chromeHost") as? NSView)
        let sidebarChromeHost = try XCTUnwrap(mirror.descendant("sidebarChromeHost") as? NSView)
        let zoomChromeHost = try XCTUnwrap(mirror.descendant("zoomChromeHost") as? NSView)
        let contentHost = mirror.descendant("contentHost") as? NSView
        chromeHost.needsLayout = true
        chromeHost.layoutSubtreeIfNeeded()
        sidebarChromeHost.layoutSubtreeIfNeeded()
        zoomChromeHost.layoutSubtreeIfNeeded()

        let leftProbe = chromeHost.convert(
            NSPoint(x: sidebarChromeHost.frame.midX, y: sidebarChromeHost.frame.midY),
            to: container
        )
        let rightProbe = chromeHost.convert(
            NSPoint(x: zoomChromeHost.frame.midX, y: zoomChromeHost.frame.midY),
            to: container
        )
        let leftChromeHit = container.hitTest(leftProbe)
        let rightChromeHit = container.hitTest(rightProbe)
        let debugFrames = "container=\(container.frame) content=\(String(describing: contentHost?.frame)) chromeHost=\(chromeHost.frame) left=\(sidebarChromeHost.frame) right=\(zoomChromeHost.frame) leftProbe=\(leftProbe) rightProbe=\(rightProbe) leftHit=\(String(describing: leftChromeHit)) rightHit=\(String(describing: rightChromeHit))"

        XCTAssertTrue(isView(leftChromeHit, inside: sidebarChromeHost), debugFrames)
        XCTAssertTrue(isView(rightChromeHit, inside: zoomChromeHost), debugFrames)
    }

    func testThumbnailSidebarUsesFullWidthSingleColumnLayout() throws {
        let sidebar = FilePreviewPDFThumbnailSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))

        sidebar.layoutSubtreeIfNeeded()

        let mirror = Mirror(reflecting: sidebar)
        let collectionView = try XCTUnwrap(
            mirror.descendant("collectionView") as? NSCollectionView
        )
        let flowLayout = try XCTUnwrap(
            mirror.descendant("flowLayout") as? NSCollectionViewFlowLayout
        )
        let itemSize = sidebar.collectionView(
            collectionView,
            layout: flowLayout,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        )

        XCTAssertGreaterThanOrEqual(itemSize.width, sidebar.bounds.width)
        XCTAssertGreaterThan(itemSize.width, sidebar.bounds.width / 2)
    }

    func testThumbnailSidebarPreferredWidthShrinksToPortraitContent() throws {
        let document = try makePDFDocument(pageSizes: [NSSize(width: 80, height: 160)])

        let width = FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: document)

        XCTAssertEqual(width, FilePreviewPDFSizing.minimumThumbnailSidebarWidth, accuracy: 0.001)
    }

    func testThumbnailSidebarPreferredWidthUsesThumbnailMinimumWithoutDocument() {
        let width = FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: nil)

        XCTAssertEqual(width, FilePreviewPDFSizing.minimumThumbnailSidebarWidth, accuracy: 0.001)
    }

    func testThumbnailSidebarPreferredWidthExpandsForLandscapeContent() throws {
        let document = try makePDFDocument(pageSizes: [NSSize(width: 160, height: 90)])

        let width = FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: document)

        XCTAssertGreaterThan(width, 200)
        XCTAssertLessThan(width, FilePreviewPDFSizing.maximumSidebarWidth)
    }

    func testSidebarWidthClampReservesMinimumContentWidth() {
        let width = FilePreviewPDFSizing.clampedSidebarWidth(
            240,
            containerWidth: FilePreviewPDFSizing.minimumSidebarWidth
                + FilePreviewPDFSizing.minimumContentWidth
                - 40,
            dividerThickness: 1
        )

        XCTAssertEqual(width, FilePreviewPDFSizing.minimumSidebarWidth, accuracy: 0.001)
    }

    func testThumbnailSidebarKeepsSingleSelectionWhenProgrammaticallyChangingPage() throws {
        let sidebar = FilePreviewPDFThumbnailSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let document = try makePDFDocument(pageCount: 5)

        sidebar.setDocument(document)
        sidebar.selectPage(at: 1, scrollToVisible: false)
        sidebar.selectPage(at: 3, scrollToVisible: false)

        let mirror = Mirror(reflecting: sidebar)
        let collectionView = try XCTUnwrap(
            mirror.descendant("collectionView") as? NSCollectionView
        )

        let previousItem = sidebar.collectionView(
            collectionView,
            itemForRepresentedObjectAt: IndexPath(item: 1, section: 0)
        )
        let currentItem = sidebar.collectionView(
            collectionView,
            itemForRepresentedObjectAt: IndexPath(item: 3, section: 0)
        )

        XCTAssertFalse(try thumbnailItemSelectedState(previousItem))
        XCTAssertTrue(try thumbnailItemSelectedState(currentItem))
    }

    func testPDFViewportOriginUsesVisibleClipWidth() {
        let origin = FilePreviewViewport.clampedClipOrigin(
            documentPoint: CGPoint(x: 500, y: 700),
            anchorOffsetInClip: CGPoint(x: 200, y: 300),
            documentBounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_400),
            clipSize: CGSize(width: 400, height: 600)
        )

        XCTAssertEqual(origin.x, 300, accuracy: 0.001)
        XCTAssertEqual(origin.y, 400, accuracy: 0.001)
    }

    func testPDFViewportOriginCentersSmallerDocuments() {
        let origin = FilePreviewViewport.clampedClipOrigin(
            documentPoint: CGPoint(x: 54, y: 224.5),
            anchorOffsetInClip: CGPoint(x: 300, y: 400),
            documentBounds: CGRect(x: 0, y: 0, width: 108, height: 449),
            clipSize: CGSize(width: 600, height: 800)
        )

        XCTAssertEqual(origin.x, -246, accuracy: 0.001)
        XCTAssertEqual(origin.y, -175.5, accuracy: 0.001)
    }

    private func isView(_ view: NSView?, inside container: NSView) -> Bool {
        var current = view
        while let next = current {
            if next === container {
                return true
            }
            current = next.superview
        }
        return false
    }

    private func makePDFDocument(pageCount: Int) throws -> PDFDocument {
        try makePDFDocument(pageSizes: Array(repeating: NSSize(width: 80, height: 80), count: pageCount))
    }

    private func makePDFDocument(pageSizes: [NSSize]) throws -> PDFDocument {
        let document = PDFDocument()
        for (pageIndex, pageSize) in pageSizes.enumerated() {
            let image = NSImage(size: pageSize)
            image.lockFocus()
            NSColor(
                calibratedHue: CGFloat(pageIndex) / CGFloat(max(pageSizes.count, 1)),
                saturation: 0.5,
                brightness: 0.8,
                alpha: 1
            ).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: pageSize)).fill()
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            document.insert(page, at: pageIndex)
        }
        return document
    }

    private func thumbnailItemSelectedState(_ item: NSCollectionViewItem) throws -> Bool {
        try XCTUnwrap(Mirror(reflecting: item.view).descendant("isSelectedForPreview") as? Bool)
    }
}

private final class FilePreviewFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

@MainActor
final class FilePreviewFocusCoordinatorTests: XCTestCase {
    func testPDFKeyboardRoutingUsesFocusedRegion() {
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_UpArrow),
                modifiers: [],
                region: .pdfThumbnails
            ),
            .navigatePage(-1)
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_DownArrow),
                modifiers: [],
                region: .pdfThumbnails
            ),
            .navigatePage(1)
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_UpArrow),
                modifiers: [],
                region: .pdfCanvas
            ),
            .native
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_DownArrow),
                modifiers: [],
                region: .pdfOutline
            ),
            .native
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_PageDown),
                modifiers: .command,
                region: .pdfThumbnails
            ),
            .native
        )
    }

    func testCoordinatorResolvesMostSpecificRegisteredSubregion() {
        let root = FilePreviewFocusTestView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let thumbnailHost = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 240))
        let thumbnailResponder = FilePreviewFocusTestView(frame: thumbnailHost.bounds)
        thumbnailHost.addSubview(thumbnailResponder)
        root.addSubview(thumbnailHost)

        let coordinator = FilePreviewFocusCoordinator(preferredIntent: .pdfCanvas)
        coordinator.register(root: root, primaryResponder: root, intent: .pdfCanvas)
        coordinator.register(
            root: thumbnailHost,
            primaryResponder: thumbnailResponder,
            intent: .pdfThumbnails
        )

        XCTAssertEqual(coordinator.ownedIntent(for: root), .pdfCanvas)
        XCTAssertEqual(coordinator.ownedIntent(for: thumbnailResponder), .pdfThumbnails)
        XCTAssertTrue(coordinator.endpoint(for: .pdfThumbnails) === thumbnailResponder)
        coordinator.notePreferredIntent(.pdfThumbnails)
        XCTAssertEqual(coordinator.preferredIntent, .pdfThumbnails)
    }
}


final class FilePreviewDragPasteboardWriterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FilePreviewDragRegistry.shared.discardAll()
        NSPasteboard(name: .drag).clearContents()
    }

    override func tearDown() {
        NSPasteboard(name: .drag).clearContents()
        FilePreviewDragRegistry.shared.discardAll()
        super.tearDown()
    }

    func testRegistrationIsLazyAndDiscardedFromDragPasteboard() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/example.txt").standardizedFileURL
        let writer = FilePreviewDragPasteboardWriter(
            filePath: fileURL.path,
            displayTitle: "example.txt"
        )
        let dragPasteboard = NSPasteboard(name: .drag)

        XCTAssertNil(FilePreviewDragPasteboardWriter.dragID(from: dragPasteboard))
        XCTAssertTrue(writer.writableTypes(for: dragPasteboard).contains(.fileURL))
        XCTAssertEqual(
            writer.pasteboardPropertyList(forType: .fileURL) as? String,
            fileURL.absoluteString
        )

        let filePreviewData = try XCTUnwrap(
            writer.pasteboardPropertyList(forType: DragOverlayRoutingPolicy.filePreviewTransferType) as? Data
        )
        let dragID = try XCTUnwrap(FilePreviewDragPasteboardWriter.dragID(from: filePreviewData))
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: dragID))

        let bonsplitData = try XCTUnwrap(
            writer.pasteboardPropertyList(forType: FilePreviewDragPasteboardWriter.bonsplitTransferType) as? Data
        )
        XCTAssertEqual(FilePreviewDragPasteboardWriter.dragID(from: bonsplitData), dragID)
        XCTAssertEqual(dragPasteboard.data(forType: DragOverlayRoutingPolicy.filePreviewTransferType), filePreviewData)
        XCTAssertEqual(dragPasteboard.data(forType: FilePreviewDragPasteboardWriter.bonsplitTransferType), filePreviewData)
        XCTAssertEqual(dragPasteboard.string(forType: .fileURL), fileURL.absoluteString)

        FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: dragPasteboard)

        XCTAssertFalse(FilePreviewDragRegistry.shared.contains(id: dragID))
    }

    func testRegistrySweepsExpiredDragEntries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let oldID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/old.txt", displayTitle: "old.txt"),
            now: start
        )
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: oldID, now: start.addingTimeInterval(30)))

        let newID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/new.txt", displayTitle: "new.txt"),
            now: start.addingTimeInterval(61)
        )

        XCTAssertFalse(FilePreviewDragRegistry.shared.contains(id: oldID, now: start.addingTimeInterval(61)))
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: newID, now: start.addingTimeInterval(61)))
    }
}


@MainActor
final class FilePreviewPanelTextSavingTests: XCTestCase {
    func testSaveTextContentWritesLiveTextViewContent() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        await panel.loadTextContent().value
        let textView = NSTextView()
        textView.string = "edited from text view"
        panel.attachTextView(textView)

        let task = try XCTUnwrap(panel.saveTextContent())
        XCTAssertTrue(panel.isSaving)
        await task.value

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "edited from text view")
        XCTAssertEqual(panel.textContent, "edited from text view")
        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isSaving)
    }

    func testSaveTextContentIgnoresConcurrentSaveRequest() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        await panel.loadTextContent().value
        panel.updateTextContent("first save")

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)

        let firstSave = try XCTUnwrap(panel.saveTextContent())
        XCTAssertTrue(panel.isSaving)

        panel.updateTextContent("second save")
        XCTAssertNil(panel.saveTextContent())

        let pipeRead = Task.detached { () throws -> String in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return String(data: handle.availableData, encoding: .utf8) ?? ""
        }

        let savedContent = try await pipeRead.value
        XCTAssertEqual(savedContent, "first save")
        await firstSave.value

        XCTAssertEqual(panel.textContent, "second save")
        XCTAssertTrue(panel.isDirty)
        XCTAssertFalse(panel.isSaving)
    }

    func testCleanSaveDoesNotCancelPendingTextLoad() async throws {
        let url = try temporaryTextFile(contents: "", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        await panel.loadTextContent().value

        try "loaded after clean save".write(to: url, atomically: true, encoding: .utf8)

        let loadTask = panel.loadTextContent()
        XCTAssertNil(panel.saveTextContent())
        await loadTask.value

        XCTAssertEqual(panel.textContent, "loaded after clean save")
        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isFileUnavailable)
    }

    func testSavingTextViewUsesConfiguredSaveShortcut() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "u", command: true, shift: false, option: true, control: false),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "saved by configured shortcut"
        textView.panel = panel
        panel.attachTextView(textView)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "u",
            charactersIgnoringModifiers: "u",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_U)
        ))

        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        await waitForPanelSave(panel)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved by configured shortcut")
    }

    func testSavingTextViewDoesNotUseDefaultSaveShortcutAfterRemap() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "u", command: true, shift: false, option: true, control: false),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "should not save through command s"
        textView.panel = panel
        panel.attachTextView(textView)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_S)
        ))

        XCTAssertFalse(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testSaveTextContentPreservesLoadedEncoding() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        await panel.loadTextContent().value
        panel.updateTextContent("edited")
        if let task = panel.saveTextContent() {
            await task.value
        }

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf16), "edited")
        XCTAssertFalse(panel.isDirty)
    }

    func testSaveTextContentWritesThroughSymlink() async throws {
        let targetURL = try temporaryTextFile(contents: "original", encoding: .utf8)
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: linkURL.path)
        await panel.loadTextContent().value
        panel.updateTextContent("edited through link")
        if let task = panel.saveTextContent() {
            await task.value
        }

        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "edited through link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), targetURL.path)
        XCTAssertFalse(panel.isDirty)
    }

    func testCleanSaveDoesNotWriteReadOnlyTextFile() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        await panel.loadTextContent().value
        if let task = panel.saveTextContent() {
            await task.value
        }

        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isFileUnavailable)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testLoadTextContentClearsDirtyStateWhenFileVanishes() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        await panel.loadTextContent().value
        panel.updateTextContent("edited")
        try FileManager.default.removeItem(at: url)

        await panel.loadTextContent().value

        XCTAssertEqual(panel.textContent, "")
        XCTAssertFalse(panel.isDirty)
        XCTAssertTrue(panel.isFileUnavailable)
    }

    func testTextEditorInsetsReapplyWhenMovedBetweenWindows() {
        _ = NSApplication.shared
        let textView = SavingTextView()
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5

        let firstWindow = windowHosting(textView)
        XCTAssertEqual(textView.textContainerInset.width, FilePreviewTextEditorLayout.textContainerInset.width)
        XCTAssertEqual(textView.textContainerInset.height, FilePreviewTextEditorLayout.textContainerInset.height)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, FilePreviewTextEditorLayout.lineFragmentPadding)

        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5

        let secondWindow = windowHosting(textView)
        XCTAssertEqual(textView.textContainerInset.width, FilePreviewTextEditorLayout.textContainerInset.width)
        XCTAssertEqual(textView.textContainerInset.height, FilePreviewTextEditorLayout.textContainerInset.height)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, FilePreviewTextEditorLayout.lineFragmentPadding)

        withExtendedLifetime([firstWindow, secondWindow]) {}
    }

    func testPendingTextFocusAppliesWhenTextViewAttaches() throws {
        _ = NSApplication.shared
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        panel.focus()

        let textView = SavingTextView()
        let window = windowHosting(textView)
        panel.attachTextView(textView)

        XCTAssertTrue(window.firstResponder === textView)
        withExtendedLifetime(window) {}
    }

    func testPDFExtensionWinsOverLooseTextSniff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8).write(to: url)

        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .pdf)
        XCTAssertEqual(FilePreviewKindResolver.tabIconName(for: url), "doc.richtext")
    }

    func testUTF16TextWithBOMStillResolvesAsText() throws {
        let url = try temporaryTextFile(contents: "hello", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
        XCTAssertEqual(FilePreviewKindResolver.tabIconName(for: url), "doc.text")
    }

    func testExtensionlessTextFileResolvesToTextAfterFastInitialClassification() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try "extensionless text".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        await waitForPanelPreviewMode(panel, .text)
        await waitForPanelTextContent(panel, "extensionless text")

        XCTAssertEqual(panel.displayIcon, "doc.text")
    }

    func testBinaryPlistDoesNotOpenAsEditableText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("bplist00".utf8).write(to: url)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertNotEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    private func temporaryTextFile(contents: String, encoding: String.Encoding) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func waitForPanelSave(
        _ panel: FilePreviewPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if !panel.isSaving {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview save", file: file, line: line)
    }

    private func waitForPanelPreviewMode(
        _ panel: FilePreviewPanel,
        _ mode: FilePreviewMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if panel.previewMode == mode {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview mode", file: file, line: line)
    }

    private func waitForPanelTextContent(
        _ panel: FilePreviewPanel,
        _ content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if panel.textContent == content {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview text content", file: file, line: line)
    }

    private func windowHosting(_ textView: NSTextView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)
        scrollView.documentView = textView
        return window
    }
}


final class BonsplitTabDragPayloadTests: XCTestCase {
    func testRejectsFilePreviewCompatibilityPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: "filePreview", includesFilePreviewTransferType: true)

        XCTAssertNil(
            BonsplitTabDragPayload.transfer(from: pasteboard),
            "Sidebar workspace drop targets should ignore file-preview drags instead of treating them as movable tabs"
        )
    }

    func testAcceptsRealFilePreviewTabPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: "filePreview")

        XCTAssertNotNil(
            BonsplitTabDragPayload.transfer(from: pasteboard),
            "Existing file-preview tabs should still move through normal Bonsplit tab drag paths"
        )
    }

    func testAcceptsRegularCurrentProcessTabPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: nil)

        XCTAssertNotNil(BonsplitTabDragPayload.transfer(from: pasteboard))
    }

    private func makeBonsplitPayloadPasteboard(
        kind: String?,
        includesFilePreviewTransferType: Bool = false
    ) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.bonsplit.\(UUID().uuidString)"))
        pasteboard.clearContents()

        var tab: [String: Any] = ["id": UUID().uuidString]
        if let kind {
            tab["kind"] = kind
        }
        let payload: [String: Any] = [
            "tab": tab,
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier))
        if includesFilePreviewTransferType {
            pasteboard.setData(data, forType: DragOverlayRoutingPolicy.filePreviewTransferType)
        }
        return pasteboard
    }
}


@MainActor
final class FileDropOverlayViewTests: XCTestCase {
    private func makeContentViewWindow(windowId: UUID = UUID()) -> NSWindow {
        _ = NSApplication.shared

        let root = ContentView(updateViewModel: UpdateViewModel(), windowId: windowId)
            .environmentObject(TabManager())
            .environmentObject(TerminalNotificationStore.shared)
            .environmentObject(SidebarState())
            .environmentObject(SidebarSelectionState())
            .environmentObject(FileExplorerState())
            .environmentObject(CmuxConfigStore())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = MainWindowHostingView(rootView: root)
        return window
    }

    private func fileDropOverlays(in root: NSView?) -> [FileDropOverlayView] {
        guard let root else { return [] }

        var overlays: [FileDropOverlayView] = []
        if let overlay = root as? FileDropOverlayView {
            overlays.append(overlay)
        }
        for subview in root.subviews {
            overlays.append(contentsOf: fileDropOverlays(in: subview))
        }
        return overlays
    }

    private final class DragSpyWebView: WKWebView {
        var dragCalls: [String] = []

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            dragCalls.append("entered")
            return .copy
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            dragCalls.append("prepare")
            return true
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            dragCalls.append("perform")
            return true
        }

        override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
            dragCalls.append("conclude")
        }
    }

    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation
        let draggingLocation: NSPoint
        let draggedImageLocation: NSPoint
        let draggedImage: NSImage?
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        nonisolated(unsafe) let draggingSource: Any?
        let draggingSequenceNumber: Int
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(
            window: NSWindow,
            location: NSPoint,
            pasteboard: NSPasteboard,
            sourceOperationMask: NSDragOperation = .copy,
            draggingSource: Any? = nil,
            sequenceNumber: Int = 1
        ) {
            self.draggingDestinationWindow = window
            self.draggingSourceOperationMask = sourceOperationMask
            self.draggingLocation = location
            self.draggedImageLocation = location
            self.draggedImage = nil
            self.draggingPasteboard = pasteboard
            self.draggingSource = draggingSource
            self.draggingSequenceNumber = sequenceNumber
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}

        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
            nil
        }

        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}

        func resetSpringLoading() {}
    }

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testContentViewInstallsSingleFileDropOverlayAcrossRepeatedLayouts() {
        let window = makeContentViewWindow()
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        realizeWindowLayout(window)
        realizeWindowLayout(window)
        realizeWindowLayout(window)

        guard let themeFrame = window.contentView?.superview else {
            XCTFail("Expected theme frame")
            return
        }

        let overlays = fileDropOverlays(in: themeFrame)
        XCTAssertEqual(
            overlays.count,
            1,
            "ContentView should install exactly one FileDropOverlayView even after repeated layout passes"
        )
        XCTAssertTrue(
            (objc_getAssociatedObject(window, &fileDropOverlayKey) as? FileDropOverlayView) === overlays.first,
            "The window-associated file-drop overlay should match the single installed view"
        )
    }

    func testOverlayResolvesPortalHostedBrowserWebViewForFileDrops() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 36, width: 220, height: 150))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)

        let overlay = FileDropOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)

        let point = anchor.convert(
            NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY),
            to: nil
        )
        XCTAssertTrue(
            overlay.webViewUnderPoint(point) === webView,
            "File-drop overlay should resolve portal-hosted browser panes so Finder uploads still reach WKWebView"
        )
    }

    func testOverlayDoesNotCaptureFileDragLifecycleWhenPanePreviewDropsAreEnabled() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let anchor = NSView(frame: NSRect(x: 52, y: 44, width: 210, height: 140))
        contentView.addSubview(anchor)

        let webView = DragSpyWebView(frame: .zero, configuration: WKWebViewConfiguration())
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }

        let overlay = FileDropOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.drag.\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/upload.mov") as NSURL]),
            "Expected file URL drag payload"
        )

        let dropPoint = anchor.convert(
            NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY),
            to: nil
        )
        let dragInfo = MockDraggingInfo(
            window: window,
            location: dropPoint,
            pasteboard: pasteboard
        )

        XCTAssertEqual(overlay.draggingEntered(dragInfo), [])
        XCTAssertFalse(overlay.prepareForDragOperation(dragInfo))
        XCTAssertFalse(overlay.performDragOperation(dragInfo))
        overlay.concludeDragOperation(dragInfo)

        XCTAssertEqual(
            webView.dragCalls,
            [],
            "Finder file drops should reach pane-level Bonsplit preview targets instead of the root overlay"
        )
    }
}


@MainActor
final class MarkdownPanelPointerObserverViewTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow,
        eventNumber: Int = 1
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Expected to create mouse event")
        }
        return event
    }

    func testObserverTriggersFocusForVisibleLeftClickInsideBounds() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let overlay = MarkdownPanelPointerObserverView(frame: contentView.bounds)
        overlay.autoresizingMask = [.width, .height]
        let focusExpectation = expectation(description: "observer forwards focus callback")
        var pointerDownCount = 0
        overlay.onPointerDown = {
            pointerDownCount += 1
            focusExpectation.fulfill()
        }
        contentView.addSubview(overlay)

        _ = overlay.handleEventIfNeeded(
            makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 60, y: 60), window: window)
        )
        wait(for: [focusExpectation], timeout: 1.0)

        XCTAssertEqual(pointerDownCount, 1)
    }

    func testObserverIgnoresOutsideOrForeignWindowClicks() {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let otherWindow = makeWindow()
        defer { otherWindow.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let overlay = MarkdownPanelPointerObserverView(frame: contentView.bounds)
        overlay.autoresizingMask = [.width, .height]
        let noFocusExpectation = expectation(description: "observer ignores invalid clicks")
        noFocusExpectation.isInverted = true
        var pointerDownCount = 0
        overlay.onPointerDown = {
            pointerDownCount += 1
            noFocusExpectation.fulfill()
        }
        contentView.addSubview(overlay)

        _ = overlay.handleEventIfNeeded(
            makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 400, y: 400), window: window)
        )
        _ = overlay.handleEventIfNeeded(
            makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 60, y: 60), window: otherWindow, eventNumber: 2)
        )
        _ = overlay.handleEventIfNeeded(
            makeMouseEvent(type: .leftMouseDragged, location: NSPoint(x: 60, y: 60), window: window, eventNumber: 3)
        )
        wait(for: [noFocusExpectation], timeout: 0.1)

        XCTAssertEqual(pointerDownCount, 0)
    }

    func testObserverDoesNotParticipateInHitTesting() {
        let overlay = MarkdownPanelPointerObserverView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertNil(overlay.hitTest(NSPoint(x: 40, y: 30)))
    }
}

@MainActor
final class TmuxWorkspacePaneOverlayTests: XCTestCase {
    func testTmuxWorkspacePaneOverlayModelTracksFlashReason() {
        let model = TmuxWorkspacePaneOverlayModel()
        let initialState = TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            flashToken: 1,
            flashReason: .notificationArrival
        )
        let laterState = TmuxWorkspacePaneOverlayRenderState(
            workspaceId: initialState.workspaceId,
            unreadRects: [],
            flashRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            flashToken: 2,
            flashReason: .navigation
        )

        model.apply(initialState)
        model.apply(laterState)

        XCTAssertEqual(model.flashReason, .navigation)
    }

    func testNavigationFlashUsesNonNotificationPresentation() {
        XCTAssertNotEqual(
            WorkspaceAttentionCoordinator.flashStyle(for: .navigation),
            WorkspaceAttentionCoordinator.flashStyle(for: .notificationArrival)
        )
    }

    func testNavigationFlashUsesNonNeutralAccent() {
        XCTAssertEqual(
            WorkspaceAttentionCoordinator.flashStyle(for: .navigation).accent,
            .navigationTeal
        )
    }

    func testTmuxWorkspacePaneExactRectReturnsContentRelativeFrameForDescendantView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected contentView")
            return
        }

        let targetView = NSView(frame: NSRect(x: 120, y: 48, width: 300, height: 200))
        contentView.addSubview(targetView)

        XCTAssertEqual(
            ContentView.tmuxWorkspacePaneExactRect(for: targetView, in: contentView),
            CGRect(x: 120, y: 48, width: 300, height: 200)
        )
    }
}

@MainActor
final class ApplicationAccessibilityHierarchyCacheTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        return window
    }

    private func assertWindowsEqual(_ actual: Any?, _ expected: [NSWindow], file: StaticString = #filePath, line: UInt = #line) {
        guard let actualWindows = actual as? [NSWindow] else {
            XCTFail("Expected NSWindow array", file: file, line: line)
            return
        }
        guard actualWindows.count == expected.count else {
            XCTFail("Expected \(expected.count) windows, got \(actualWindows.count)", file: file, line: line)
            return
        }
        for (lhs, rhs) in zip(actualWindows, expected) {
            XCTAssertTrue(lhs === rhs, file: file, line: line)
        }
    }

    func testRepeatedWindowsQueriesReuseSingleHierarchyBuildUntilStateChanges() {
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        defer {
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }

        let cache = CmuxApplicationAccessibilityHierarchyCache()
        let state = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [firstWindow, secondWindow])
        var buildCount = 0

        let firstValue = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [firstWindow, secondWindow])
        }
        let secondValue = cache.value(for: .windows, stateToken: state) {
            XCTFail("Expected cached snapshot for repeated state")
            return .init(windows: [])
        }

        assertWindowsEqual(firstValue, [firstWindow, secondWindow])
        assertWindowsEqual(secondValue, [firstWindow, secondWindow])
        XCTAssertEqual(buildCount, 1, "Expected a single hierarchy build for repeated AX queries with no invalidation")
    }

    func testChangedStateTokenInvalidatesCachedHierarchySnapshot() {
        let window = makeWindow()
        let otherWindow = makeWindow()
        defer {
            window.orderOut(nil)
            otherWindow.orderOut(nil)
        }

        let cache = CmuxApplicationAccessibilityHierarchyCache()
        let initialState = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [window])
        let updatedState = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [window, otherWindow])
        var buildCount = 0

        _ = cache.value(for: .windows, stateToken: initialState) {
            buildCount += 1
            return .init(windows: [window])
        }
        let updatedWindowsValue = cache.value(for: .windows, stateToken: updatedState) {
            buildCount += 1
            return .init(windows: [window, otherWindow])
        }

        assertWindowsEqual(updatedWindowsValue, [window, otherWindow])
        XCTAssertEqual(buildCount, 2, "Expected the cache to rebuild once after the hierarchy token changes")
    }

    func testNonWindowsAttributesStayPassthrough() {
        let cache = CmuxApplicationAccessibilityHierarchyCache()

        for attribute: NSAccessibility.Attribute in [.children, .visibleChildren, .mainWindow, .focusedWindow] {
            switch cache.resolve(attribute: attribute, application: NSApp) {
            case .passthrough:
                break
            case .handled:
                XCTFail("Expected \(attribute.rawValue) to fall back to AppKit")
            }
        }
    }

    func testWindowCloseNotificationInvalidatesCache() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let center = NotificationCenter()
        let cache = CmuxApplicationAccessibilityHierarchyCache(notificationCenter: center)
        let state = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [window])
        var buildCount = 0

        _ = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [window])
        }
        center.post(name: NSWindow.willCloseNotification, object: window)
        _ = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [window])
        }

        XCTAssertEqual(buildCount, 2, "Expected NSWindow.willCloseNotification to invalidate the cache")
    }
}
#endif
