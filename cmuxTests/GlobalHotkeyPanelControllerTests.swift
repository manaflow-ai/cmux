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
        XCTAssertEqual(GlobalHotkeyPanelConfiguration.windowIdentifier, "cmux.hotkeyPanel")
        XCTAssertTrue(panel.acceptsFirstResponder)
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
        XCTAssertGreaterThanOrEqual(frame.width, screenFrame.width * 0.85)
        XCTAssertGreaterThanOrEqual(frame.height, screenFrame.height * 0.75)
        XCTAssertEqual(frame.midX, screenFrame.midX, accuracy: 1)
        XCTAssertEqual(frame.maxY, screenFrame.maxY - max(20, min(56, screenFrame.height * 0.045)), accuracy: 1)
    }

    func testHotkeyPanelContextRoleIsTransient() {
        XCTAssertTrue(AppDelegate.MainWindowContextRole.standard.isSessionRestorable)
        XCTAssertFalse(AppDelegate.MainWindowContextRole.globalHotkeyPanel.isSessionRestorable)
    }

    func testContentStateLoadsConfigurationDuringInitialization() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hotkey-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let configURL = tempDirectory.appendingPathComponent("cmux.json")
        let configJSON = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "command": "echo hotkey" }
              ]
            }
          }
        }
        """
        try configJSON.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            startFileWatchers: false
        )
        XCTAssertEqual(store.configRevision, 0)

        _ = GlobalHotkeyPanelContentState(
            tabManager: TabManager(autoWelcomeIfNeeded: false),
            cmuxConfigStore: store
        )

        XCTAssertGreaterThan(store.configRevision, 0)
        XCTAssertEqual(store.surfaceTabBarButtonSourcePath, configURL.path)
        XCTAssertEqual(store.surfaceTabBarButtons.first?.terminalCommand, "echo hotkey")
    }

    func testHidingHotkeyPanelRestoresVisibleStandardWindowContext() {
        _ = NSApplication.shared
        let appDelegate = AppDelegate()
        let standardWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let panel = GlobalHotkeyPanel(
            contentRect: NSRect(x: 20, y: 20, width: 800, height: 600),
            styleMask: GlobalHotkeyPanelConfiguration.styleMask,
            backing: .buffered,
            defer: false
        )
        defer {
            standardWindow.orderOut(nil)
            panel.orderOut(nil)
            standardWindow.close()
            panel.close()
        }

        let standardManager = TabManager(autoWelcomeIfNeeded: false)
        let hotkeyManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.registerMainWindow(
            standardWindow,
            windowId: UUID(),
            tabManager: standardManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState(),
            role: .standard
        )
        appDelegate.registerMainWindow(
            panel,
            windowId: UUID(),
            tabManager: hotkeyManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState(),
            role: .globalHotkeyPanel
        )

        standardWindow.orderFront(nil)
        appDelegate.setActiveMainWindow(panel)
        XCTAssertTrue(appDelegate.tabManager === hotkeyManager)

        panel.orderOut(nil)
        appDelegate.restoreActiveMainWindowAfterHiding(panel)

        XCTAssertTrue(appDelegate.tabManager === standardManager)
    }

    func testDiscardingActiveStandardContextDoesNotFallBackToHotkeyPanel() {
        _ = NSApplication.shared
        let appDelegate = AppDelegate()
        let standardWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let panel = GlobalHotkeyPanel(
            contentRect: NSRect(x: 20, y: 20, width: 800, height: 600),
            styleMask: GlobalHotkeyPanelConfiguration.styleMask,
            backing: .buffered,
            defer: false
        )
        defer {
            standardWindow.orderOut(nil)
            panel.orderOut(nil)
            standardWindow.close()
            panel.close()
        }

        let standardWindowId = UUID()
        let standardManager = TabManager(autoWelcomeIfNeeded: false)
        let hotkeyManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.registerMainWindow(
            standardWindow,
            windowId: standardWindowId,
            tabManager: standardManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState(),
            role: .standard
        )
        appDelegate.registerMainWindow(
            panel,
            windowId: UUID(),
            tabManager: hotkeyManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState(),
            role: .globalHotkeyPanel
        )

        appDelegate.setActiveMainWindow(standardWindow)
        XCTAssertTrue(appDelegate.tabManager === standardManager)

        appDelegate.unregisterMainWindowContextForTesting(windowId: standardWindowId)

        XCTAssertNil(appDelegate.tabManager)
        XCTAssertFalse(appDelegate.tabManager === hotkeyManager)
    }
}
