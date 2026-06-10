import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Window chrome, titlebar, and minimal mode tests
extension AppDelegateShortcutRoutingTests {
    func testMinimalModeUsesZeroTopSafeAreaForMainWindowContentView() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        let savedLegacyTitlebar = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebar, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId),
              let contentView = window.contentView else {
            XCTFail("Expected main window content view")
            return
        }

        contentView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(
            contentView.safeAreaInsets.top,
            0,
            accuracy: 0.5,
            "Minimal mode should not leave a top safe-area inset in the main window content view"
        )
    }

    func testMinimalModeTitlebarPaddingOnlyCancelsHostingSafeArea() {
        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: false,
                isFullScreen: false,
                titlebarPadding: 32,
                hostingSafeAreaTop: 0
            ),
            WindowChromeMetrics.appTitlebarHeight,
            accuracy: 0.5,
            "Standard mode should align terminal content with cmux's visual titlebar height even when AppKit reports a taller native titlebar zone"
        )

        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: true,
                isFullScreen: true,
                titlebarPadding: 32,
                hostingSafeAreaTop: 32
            ),
            0,
            accuracy: 0.5,
            "Fullscreen minimal mode should not offset for a titlebar"
        )

        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: true,
                isFullScreen: false,
                titlebarPadding: 32,
                hostingSafeAreaTop: 0
            ),
            0,
            accuracy: 0.5,
            "Manually hosted minimal windows already have zero safe area, so the Bonsplit strip must not be pulled offscreen"
        )

        XCTAssertEqual(
            ContentView.effectiveTitlebarPadding(
                isMinimalMode: true,
                isFullScreen: false,
                titlebarPadding: 32,
                hostingSafeAreaTop: 28
            ),
            -28,
            accuracy: 0.5,
            "SwiftUI WindowGroup windows still need their native titlebar safe area cancelled"
        )
    }

    func testNotificationsPopoverVisibilityIsScopedByWindow() {
        let state = NotificationsPopoverVisibilityState.shared
        state.resetForTesting()
        defer { state.resetForTesting() }

        let firstPopover = NSObject()
        let secondPopover = NSObject()

        state.setShown(true, source: firstPopover, windowNumber: 101)
        XCTAssertTrue(state.isShown)
        XCTAssertTrue(state.isShown(in: 101))
        XCTAssertFalse(state.isShown(in: 202))

        state.setShown(true, source: secondPopover, windowNumber: 202)
        XCTAssertTrue(state.isShown(in: 101))
        XCTAssertTrue(state.isShown(in: 202))

        state.setShown(false, source: firstPopover)
        XCTAssertTrue(state.isShown)
        XCTAssertFalse(state.isShown(in: 101))
        XCTAssertTrue(state.isShown(in: 202))

        state.setShown(false, source: secondPopover)
        XCTAssertFalse(state.isShown)
        XCTAssertFalse(state.isShown(in: 101))
        XCTAssertFalse(state.isShown(in: 202))
    }

    func testWindowChromeTitlebarHeightClampsToSharedRange() {
        [WindowChromeMetrics.appTitlebarHeight, WindowChromeMetrics.bonsplitTabBarHeight, WindowChromeMetrics.secondaryTitlebarHeight, MinimalModeChromeMetrics.titlebarHeight, RightSidebarChromeMetrics.titlebarHeight, RightSidebarChromeMetrics.secondaryBarHeight].forEach { XCTAssertEqual($0, WindowChromeMetrics.sharedChromeBarHeight) }
        XCTAssertEqual(WindowChromeMetrics.clampedTitlebarHeight(12), 28)
        XCTAssertEqual(WindowChromeMetrics.clampedTitlebarHeight(32), 32)
        XCTAssertEqual(WindowChromeMetrics.clampedTitlebarHeight(96), 72)
    }

    func testRightSidebarHeaderChromeUsesSharedButtonsWithCompactIcons() {
        let titlebarConfig = TitlebarControlsStyle.classic.config

        XCTAssertEqual(HeaderChromeControlMetrics.buttonSize, titlebarConfig.buttonSize, accuracy: 0.001)
        XCTAssertEqual(HeaderChromeControlMetrics.iconSize, titlebarConfig.iconSize, accuracy: 0.001)
        XCTAssertEqual(HeaderChromeControlMetrics.cornerRadius, titlebarConfig.buttonCornerRadius, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.headerControlSize, titlebarConfig.buttonSize, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.headerIconSize, 10, accuracy: 0.001)
        XCTAssertEqual(
            RightSidebarChromeMetrics.headerIconFrameSize,
            RightSidebarChromeMetrics.headerIconSize,
            accuracy: 0.001
        )
        XCTAssertLessThan(RightSidebarChromeMetrics.headerIconSize, titlebarConfig.iconSize)
        XCTAssertLessThan(
            RightSidebarChromeMetrics.headerIconFrameSize,
            HeaderChromeIconStyle.iconFrameSize(forIconSize: titlebarConfig.iconSize)
        )
        XCTAssertEqual(RightSidebarChromeMetrics.headerControlCornerRadius, titlebarConfig.buttonCornerRadius, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.controlHeight, RightSidebarChromeMetrics.headerControlSize, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.barVerticalPadding, 4, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeMetrics.headerControlCenterAlignmentAdjustment, 0, accuracy: 0.001)
    }

    func testRightSidebarPillChromeUsesHeaderIconColorAndWeight() {
        XCTAssertEqual(RightSidebarChromeControlStyle.iconWeight, HeaderChromeIconStyle.weight)
        XCTAssertEqual(RightSidebarChromeControlStyle.labelWeight, HeaderChromeIconStyle.weight)
        XCTAssertEqual(RightSidebarChromeControlStyle.modeIconSize, 11, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeControlStyle.secondaryIconSize, 10, accuracy: 0.001)
        XCTAssertEqual(RightSidebarChromeControlStyle.labelSize, 11, accuracy: 0.001)
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: false, isHovered: false),
            HeaderChromeIconStyle.foregroundOpacity(isHovering: false, isPressed: false),
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: false, isHovered: true),
            HeaderChromeIconStyle.foregroundOpacity(isHovering: true, isPressed: false),
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: true, isHovered: false),
            HeaderChromeIconStyle.pressedOpacity,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RightSidebarChromeControlStyle.foregroundOpacity(isSelected: false, isHovered: true, isEnabled: false),
            HeaderChromeIconStyle.disabledOpacity,
            accuracy: 0.001
        )
    }

    func testMinimalModeCollapsedSidebarResyncsTrafficLightInsetAfterNewWorkspaceCreation() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
        }

        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: false, selection: .tabs, width: nil)
        )
        let windowId = appDelegate.createMainWindow(sessionWindowSnapshot: snapshot)
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected tab manager for created window")
            return
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: windowId), false)

        guard let sourceWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace")
            return
        }

        // Recreate the regression shape: the window chrome state says minimal +
        // collapsed sidebar, but the selected workspace's live Bonsplit inset is stale.
        sourceWorkspace.bonsplitController.configuration.appearance.tabBarLeadingInset = 0

        guard let newWorkspaceId = appDelegate.addWorkspaceInPreferredMainWindow(debugSource: "test.issue2737") else {
            XCTFail("Expected workspace creation to route to the test window")
            return
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        guard let newWorkspace = manager.tabs.first(where: { $0.id == newWorkspaceId }) else {
            XCTFail("Expected new workspace in test window")
            return
        }

        XCTAssertEqual(
            newWorkspace.bonsplitController.configuration.appearance.tabBarLeadingInset,
            80,
            accuracy: 0.5,
            "New minimal-mode workspaces should reserve traffic-light space immediately even when the source workspace inset is stale"
        )
    }

    func testMinimalModeCollapsedSidebarSeedsTrafficLightInsetOnNewWindowCreation() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
        }

        // Simulate the new-window flow: createMainWindow with a snapshot that forces
        // sidebar collapsed. The initial workspace is created inside TabManager.init,
        // before ContentView.onAppear can run syncTrafficLightInset — so the seed in
        // createMainWindow is what protects the first render.
        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: false, selection: .tabs, width: nil)
        )
        let windowId = appDelegate.createMainWindow(sessionWindowSnapshot: snapshot)
        defer { closeWindow(withId: windowId) }

        guard let manager = appDelegate.tabManagerFor(windowId: windowId) else {
            XCTFail("Expected tab manager for created window")
            return
        }

        XCTAssertEqual(appDelegate.sidebarVisibility(windowId: windowId), false)

        guard let initialWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected selected workspace in fresh window")
            return
        }

        // No RunLoop spin before reading the inset — the seed must be applied by the
        // time createMainWindow returns, not lazily after onAppear runs.
        XCTAssertEqual(
            initialWorkspace.bonsplitController.configuration.appearance.tabBarLeadingInset,
            80,
            accuracy: 0.5,
            "New minimal-mode windows with collapsed sidebar should reserve traffic-light space on the initial workspace before first render"
        )
    }

    func testAttachUpdateAccessoryHidesTitlebarAccessoryWhenMinimalModeEnabled() {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("Expected AppDelegate.shared")
            return
        }

        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        let savedLegacyTitlebar = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set(WorkspacePresentationModeSettings.Mode.standard.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebar, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
        }

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        guard let window = window(withId: windowId) else {
            XCTFail("Expected main window")
            return
        }

        let titlebarAccessory: () -> NSTitlebarAccessoryViewController? = {
            window.titlebarAccessoryViewControllers.first {
                $0.view.identifier?.rawValue == "cmux.titlebarControls"
            }
        }

        guard let initialAccessory = titlebarAccessory() else {
            XCTFail("Expected visible-titlebar mode to attach the titlebar accessory")
            return
        }
        XCTAssertFalse(initialAccessory.isHidden, "Expected visible-titlebar mode to show the titlebar accessory")

        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        appDelegate.attachUpdateAccessory(to: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let minimalAccessory = titlebarAccessory() else {
            XCTFail("Minimal mode should keep a hidden titlebar accessory so shortcut-driven popovers still have a controller")
            return
        }
        XCTAssertTrue(minimalAccessory.isHidden, "Minimal mode should hide titlebar accessories")
        XCTAssertTrue(minimalAccessory.view.isHidden, "Minimal mode should hide the titlebar accessory view")
        XCTAssertEqual(minimalAccessory.view.alphaValue, 0, accuracy: 0.01)
    }

    func testWorkspaceButtonFadeModeDefaultsOffWhenTitlebarVisible() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defaults.set(true, forKey: WorkspaceTitlebarSettings.showTitlebarKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.disabled.rawValue
        )
    }

    func testWorkspaceButtonFadeModeDefaultsOnWhenTitlebarHidden() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.enabled.rawValue
        )
    }

    func testWorkspaceButtonFadeModeMigratesLegacyHoverVisibilityPreference() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.set(true, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set("always", forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.set("onHover", forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.enabled.rawValue
        )
    }

    func testWorkspaceButtonFadeModePreservesExistingStoredMode() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        let savedTitlebarVisibility = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyTitlebarMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        let savedLegacyPaneMode = defaults.object(forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedTitlebarVisibility, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebarMode, forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyPaneMode, forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey, defaults: defaults)
        }

        defaults.set(WorkspaceButtonFadeSettings.Mode.disabled.rawValue, forKey: WorkspaceButtonFadeSettings.modeKey)
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set("onHover", forKey: WorkspaceButtonFadeSettings.legacyTitlebarControlsVisibilityModeKey)
        defaults.set("onHover", forKey: WorkspaceButtonFadeSettings.legacyPaneTabBarControlsVisibilityModeKey)

        WorkspaceButtonFadeSettings.initializeStoredModeIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: WorkspaceButtonFadeSettings.modeKey),
            WorkspaceButtonFadeSettings.Mode.disabled.rawValue
        )
    }

    func testWorkspaceMinimalModeDefaultsToStandardPresentation() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        let savedLegacyTitlebar = defaults.object(forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        let savedLegacyFade = defaults.object(forKey: WorkspaceButtonFadeSettings.modeKey)
        defer {
            restoreDefaultsValue(savedMode, forKey: WorkspacePresentationModeSettings.modeKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyTitlebar, forKey: WorkspaceTitlebarSettings.showTitlebarKey, defaults: defaults)
            restoreDefaultsValue(savedLegacyFade, forKey: WorkspaceButtonFadeSettings.modeKey, defaults: defaults)
        }

        defaults.removeObject(forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(false, forKey: WorkspaceTitlebarSettings.showTitlebarKey)
        defaults.set(WorkspaceButtonFadeSettings.Mode.enabled.rawValue, forKey: WorkspaceButtonFadeSettings.modeKey)

        XCTAssertEqual(
            WorkspacePresentationModeSettings.mode(defaults: defaults),
            .standard
        )
    }

}
