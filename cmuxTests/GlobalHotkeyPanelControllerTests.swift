import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GlobalHotkeyPanelControllerTests: XCTestCase {
    func testPanelConfigurationUsesFullscreenAuxiliaryNonActivatingPanel() {
        let panel = GlobalHotkeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: GlobalHotkeyPanelConfiguration.styleMask,
            backing: .buffered,
            defer: false
        )
        defer {
            panel.orderOut(nil)
            panel.close()
        }

        GlobalHotkeyPanelConfiguration.apply(to: panel)

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.isExcludedFromWindowsMenu)
        XCTAssertEqual(panel.level, GlobalHotkeyPanelConfiguration.windowLevel)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testPanelLayoutCreatesTopOverlayInsideScreenBounds() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1_512, height: 982)
        let frame = GlobalHotkeyPanelLayout.panelFrame(in: screenFrame)

        XCTAssertGreaterThanOrEqual(frame.minX, screenFrame.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, screenFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxX, screenFrame.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, screenFrame.maxY)
        XCTAssertGreaterThan(frame.width, screenFrame.width * 0.85)
        XCTAssertGreaterThan(frame.height, screenFrame.height * 0.75)
        XCTAssertEqual(frame.midX, screenFrame.midX, accuracy: 1)
        XCTAssertEqual(frame.maxY, screenFrame.maxY - max(20, min(56, screenFrame.height * 0.045)), accuracy: 1)
    }

    func testHotkeyPanelContextRoleIsTransient() {
        XCTAssertTrue(AppDelegate.MainWindowContextRole.standard.isSessionRestorable)
        XCTAssertFalse(AppDelegate.MainWindowContextRole.globalHotkeyPanel.isSessionRestorable)
    }
}
