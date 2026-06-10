import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Minimal mode sidebar and titlebar controls
extension WindowDragHandleHitTests {
    private final class SidebarActionRegionView: NSView, MinimalModeSidebarControlActionHitRegionProviding {
        nonisolated(unsafe) var config = TitlebarControlsStyle.classic.config

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

    func testTitlebarControlGapsAreOutsideButtonHitColumns() {
        let config = TitlebarControlsStyle.classic.config
        let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)
        XCTAssertEqual(ranges.count, MinimalModeSidebarControlActionSlot.allCases.count)
        XCTAssertEqual(
            ranges[0].lowerBound,
            TitlebarControlsLayoutMetrics.hintLeadingPadding + config.groupPadding.leading,
            accuracy: 0.001,
            "Hidden titlebar hit regions should share the visible titlebar control leading position."
        )

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

    func testDragHandleYieldsToRegisteredMinimalModeSidebarButtonColumns() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let dragHandle = NSView(frame: contentView.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        contentView.addSubview(dragHandle)

        let controlRegion = SidebarActionRegionView(
            frame: NSRect(
                x: 72,
                y: 88,
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )
        )
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        let ranges = TitlebarControlsHitRegions.buttonXRanges(config: controlRegion.config)
        let backButtonPoint = NSPoint(
            x: controlRegion.frame.minX + ranges[MinimalModeSidebarControlActionSlot.focusHistoryBack.rawValue].lowerBound + 1,
            y: controlRegion.frame.midY
        )
        XCTAssertTrue(isMinimalModeTitlebarControlHit(window: window, locationInWindow: backButtonPoint))
        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                dragHandle.convert(backButtonPoint, from: nil),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Registered minimal-mode titlebar buttons should not fall through to the window drag handle."
        )

        let emptyTitlebarPoint = NSPoint(x: contentView.bounds.maxX - 20, y: controlRegion.frame.midY)
        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                dragHandle.convert(emptyTitlebarPoint, from: nil),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Empty titlebar space should still be draggable."
        )
    }

    func testMinimalModeSidebarFallbackHitUsesHardcodedLeadingInset() {
        let suiteName = "WindowDragHandleHitTests.leadingInset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: "titlebarControlsStyle")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
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

        let firstButtonX = TitlebarControlsHitRegions.buttonXRanges(config: TitlebarControlsStyle.classic.config)[0].lowerBound + 1
        let titlebarY = contentView.bounds.maxY - 4
        XCTAssertEqual(
            minimalModeSidebarControlActionSlot(
                window: window,
                locationInWindow: NSPoint(
                    x: CGFloat(MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset) + firstButtonX,
                    y: titlebarY
                ),
                defaults: defaults
            ),
            .toggleSidebar
        )
    }

    func testMinimalModeSidebarTitlebarControlsAlignWithTrafficLightCenter() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        // WindowDecorationsController.apply reads the production presentation-mode setting
        // from UserDefaults.standard, so this test saves and restores the shared key narrowly.
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            if let savedMode {
                defaults.set(savedMode, forKey: WorkspacePresentationModeSettings.modeKey)
            } else {
                defaults.removeObject(forKey: WorkspacePresentationModeSettings.modeKey)
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        defer { window.orderOut(nil) }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let closeButton = window.standardWindowButton(.closeButton),
              let closeButtonSuperview = closeButton.superview else {
            XCTFail("Expected close traffic-light button")
            return
        }

        let controller = WindowDecorationsController()
        controller.apply(to: window)

        guard let target = contentView.subviews.compactMap({ $0 as? MinimalModeSidebarControlActionView }).first else {
            XCTFail("Expected minimal sidebar titlebar click target")
            return
        }

        let trafficLightFrame = closeButtonSuperview.convert(closeButton.frame, to: contentView)
        XCTAssertEqual(
            target.frame.midY,
            trafficLightFrame.midY,
            accuracy: 0.25,
            "Minimal-mode sidebar controls should share the traffic-light center Y"
        )
    }

    func testTitlebarChromeSettingsUseDefaultsAndStoredOverrides() {
        let suiteName = "WindowDragHandleHitTests.titlebarChromeSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        XCTAssertEqual(
            snapshot.leftControlsLeadingInset,
            MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            snapshot.leftControlsTopInset,
            MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MinimalModeTitlebarDebugSettings.leftControlsLeadingInset(defaults: defaults),
            CGFloat(MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset),
            accuracy: 0.001
        )
        XCTAssertEqual(
            MinimalModeSidebarTitlebarControlsMetrics.topInset(defaults: defaults),
            CGFloat(MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset),
            accuracy: 0.001
        )

        defaults.set(44.5, forKey: MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
        defaults.set(6.5, forKey: MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
        defaults.set(12.0, forKey: "titlebarDebug.trafficLightsXOffset")
        defaults.set(-3.0, forKey: "titlebarDebug.trafficLightsYOffset")
        defaults.set(88.0, forKey: MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey)
        defaults.set(92.0, forKey: MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey)

        let storedSnapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        XCTAssertEqual(storedSnapshot.leftControlsLeadingInset, 44.5, accuracy: 0.001)
        XCTAssertEqual(storedSnapshot.leftControlsTopInset, 6.5, accuracy: 0.001)
        XCTAssertEqual(storedSnapshot.trafficLightTabBarLeadingInset, 88.0, accuracy: 0.001)
        XCTAssertEqual(storedSnapshot.trafficLightTitlebarLeadingInset, 92.0, accuracy: 0.001)

        defaults.set(999.0, forKey: MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
        XCTAssertEqual(
            MinimalModeTitlebarDebugSettings.leftControlsLeadingInset(defaults: defaults),
            CGFloat(MinimalModeTitlebarDebugSettings.horizontalInsetRange.upperBound),
            accuracy: 0.001
        )
    }

    func testTitlebarChromeSettingsIgnoreLegacyNativeTrafficLightOffsets() {
        let suiteName = "WindowDragHandleHitTests.titlebarChromeLegacyTrafficLights.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(44.0, forKey: "titlebarDebug.trafficLightsXOffset")
        defaults.set(-12.0, forKey: "titlebarDebug.trafficLightsYOffset")

        let snapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        XCTAssertEqual(
            snapshot,
            MinimalModeTitlebarDebugSnapshot(
                leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
                leftControlsTopInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
                trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
                trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
            )
        )
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

}
