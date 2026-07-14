import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserWebExtensionCreatedWindowTests {
    @MainActor
    @Test
    @available(macOS 15.4, *)
    func tabIndicesFollowAuthoritativeWorkspaceReorders() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        let manager = TabManager(browserWebExtensionHost: support)
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let first = try #require(workspace.newBrowserSurface(inPane: pane, focus: false))
        let second = try #require(workspace.newBrowserSurface(inPane: pane, focus: false))
        let window = NSWindow()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            window: window
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            workspace.teardownAllPanels()
            window.close()
        }
        manager.reconcileBrowserWebExtensionWindows(in: workspace, nativeWindow: window)
        #expect(support.indexInWindow(of: first.id) == 0)
        #expect(support.indexInWindow(of: second.id) == 1)

        #expect(workspace.reorderSurface(panelId: second.id, toIndex: 0, focus: false))

        #expect(support.indexInWindow(of: second.id) == 0)
        #expect(support.indexInWindow(of: first.id) == 1)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func clampsRequestedNormalWindowDimensionsToUsableBounds() {
        let support = BrowserWebExtensionSupport()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        let adapter = BrowserWebExtensionWindowAdapter(support: support, hostWindow: window)
        let minimumSize = CmuxMainWindow.minimumContentSize
        let screenSize = window.screen?.visibleFrame.size
            ?? NSScreen.main?.visibleFrame.size
            ?? NSSize(width: 1440, height: 900)
        let maximumSize = NSSize(
            width: max(screenSize.width, minimumSize.width),
            height: max(screenSize.height, minimumSize.height)
        )

        adapter.applyInitialConfiguration(
            requestedFrame: CGRect(x: 10, y: 20, width: -100, height: 0),
            windowState: .normal
        )

        #expect(window.frame.origin == CGPoint(x: 10, y: 20))
        #expect(window.frame.size == minimumSize)

        adapter.applyInitialConfiguration(
            requestedFrame: CGRect(
                x: 30,
                y: 40,
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            windowState: .normal
        )

        #expect(window.frame.origin == CGPoint(x: 30, y: 40))
        #expect(window.frame.size == maximumSize)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func appliesRequestedConfigurationAndAllowsOnlyCreatorToClose() async throws {
        let extensionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: extensionDirectory)
        }
        let manifest = """
        {
          "manifest_version": 3,
          "name": "Window Test Extension",
          "version": "1.0"
        }
        """
        try Data(manifest.utf8).write(
            to: extensionDirectory.appendingPathComponent("manifest.json")
        )
        let webExtension = try await WKWebExtension(resourceBaseURL: extensionDirectory)
        let creatorContext = WKWebExtensionContext(for: webExtension)
        let unrelatedContext = WKWebExtensionContext(for: webExtension)
        let appDelegate = try #require(AppDelegate.shared)
        let previousHost = appDelegate.browserWebExtensionHost
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        let hadAttemptedStartupSessionRestore = appDelegate.didAttemptStartupSessionRestore
        appDelegate.didAttemptStartupSessionRestore = false
        defer {
            appDelegate.browserWebExtensionHost = previousHost
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled)
            appDelegate.didAttemptStartupSessionRestore = hadAttemptedStartupSessionRestore
        }

        let support = BrowserWebExtensionSupport()
        appDelegate.browserWebExtensionHost = support
        BrowserAvailabilitySettings.setDisabled(false)
        let requestedFrame = CGRect(x: 140, y: 180, width: 720, height: 520)
        let adapter = try #require(support.openNormalBrowserWindow(
            requestedTabs: [(nil, nil)],
            shouldFocus: false,
            requestedFrame: requestedFrame,
            requestedWindowState: .minimized,
            extensionContext: creatorContext
        ))
        let window = try #require(adapter.hostWindow)
        let windowID = try #require(appDelegate.mainWindowId(from: window))
        let mainWindowContext = try #require(appDelegate.contextForMainTerminalWindow(window))
        #expect(!mainWindowContext.tabManager.allowsStartupSessionRestore)
        appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: mainWindowContext.tabManager,
            sidebarState: mainWindowContext.sidebarState,
            sidebarSelectionState: mainWindowContext.sidebarSelectionState,
            fileExplorerState: mainWindowContext.fileExplorerState,
            cmuxConfigStore: mainWindowContext.cmuxConfigStore
        )
        #expect(!appDelegate.didAttemptStartupSessionRestore)
        #expect(!AppDelegate.shouldSaveSessionSnapshotAfterMainWindowRegistration(
            isTerminatingApp: false,
            didApplyStartupSessionRestore: false,
            isApplyingSessionRestore: false,
            didAttemptStartupSessionRestore: appDelegate.didAttemptStartupSessionRestore
        ))
        #expect(!AppDelegate.shouldRunSessionAutosaveTick(
            isTerminatingApp: false,
            didAttemptStartupSessionRestore: appDelegate.didAttemptStartupSessionRestore
        ))
        var didCloseWindow = false
        defer {
            if !didCloseWindow {
                _ = appDelegate.closeMainWindow(windowId: windowID, recordHistory: false)
            }
        }

        #expect(window.frame == requestedFrame)
        #expect(window.isMiniaturized)
        #expect(adapter.windowState(for: creatorContext) == .minimized)

        var unrelatedCloseError: Error?
        adapter.close(for: unrelatedContext) { unrelatedCloseError = $0 }
        #expect(unrelatedCloseError != nil)
        #expect(appDelegate.contextForMainTerminalWindow(window) != nil)

        var creatorCloseError: Error?
        adapter.close(for: creatorContext) { creatorCloseError = $0 }
        didCloseWindow = creatorCloseError == nil
        #expect(creatorCloseError == nil)
        #expect(appDelegate.contextForMainTerminalWindow(window) == nil)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func userOwnedContentPermanentlyRevokesCreatorCloseAuthority() async throws {
        let extensionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-window-revoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: extensionDirectory)
        }
        let manifest = """
        {
          "manifest_version": 3,
          "name": "Window Revoke Test Extension",
          "version": "1.0"
        }
        """
        try Data(manifest.utf8).write(
            to: extensionDirectory.appendingPathComponent("manifest.json")
        )
        let webExtension = try await WKWebExtension(resourceBaseURL: extensionDirectory)
        let creatorContext = WKWebExtensionContext(for: webExtension)
        let appDelegate = try #require(AppDelegate.shared)
        let previousHost = appDelegate.browserWebExtensionHost
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        defer {
            appDelegate.browserWebExtensionHost = previousHost
            BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled)
        }

        let support = BrowserWebExtensionSupport()
        appDelegate.browserWebExtensionHost = support
        BrowserAvailabilitySettings.setDisabled(false)
        let adapter = try #require(support.openNormalBrowserWindow(
            requestedTabs: [(nil, nil)],
            shouldFocus: false,
            extensionContext: creatorContext
        ))
        let window = try #require(adapter.hostWindow)
        let windowID = try #require(appDelegate.mainWindowId(from: window))
        defer { _ = appDelegate.closeMainWindow(windowId: windowID, recordHistory: false) }
        let mainWindowContext = try #require(appDelegate.contextForMainTerminalWindow(window))
        let workspace = try #require(mainWindowContext.tabManager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let ordinaryBrowser = try #require(workspace.newBrowserSurface(inPane: pane, focus: false))
        #expect(workspace.closePanel(ordinaryBrowser.id, force: true))

        var closeError: Error?
        adapter.close(for: creatorContext) { closeError = $0 }

        #expect(closeError != nil)
        #expect(appDelegate.contextForMainTerminalWindow(window) != nil)

        let terminalAdapter = try #require(support.openNormalBrowserWindow(
            requestedTabs: [(nil, nil)],
            shouldFocus: false,
            extensionContext: creatorContext
        ))
        let terminalWindow = try #require(terminalAdapter.hostWindow)
        let terminalWindowID = try #require(appDelegate.mainWindowId(from: terminalWindow))
        defer { _ = appDelegate.closeMainWindow(windowId: terminalWindowID, recordHistory: false) }
        let terminalContext = try #require(appDelegate.contextForMainTerminalWindow(terminalWindow))
        let terminalWorkspace = try #require(terminalContext.tabManager.selectedWorkspace)
        let terminalPane = try #require(terminalWorkspace.bonsplitController.allPaneIds.first)
        let terminal = try #require(terminalWorkspace.newTerminalSurface(inPane: terminalPane, focus: false))
        #expect(terminalWorkspace.closePanel(terminal.id, force: true))

        var terminalCloseError: Error?
        terminalAdapter.close(for: creatorContext) { terminalCloseError = $0 }

        #expect(terminalCloseError != nil)
        #expect(appDelegate.contextForMainTerminalWindow(terminalWindow) != nil)

        let workspaceAdapter = try #require(support.openNormalBrowserWindow(
            requestedTabs: [(nil, nil)],
            shouldFocus: false,
            extensionContext: creatorContext
        ))
        let workspaceWindow = try #require(workspaceAdapter.hostWindow)
        let workspaceWindowID = try #require(appDelegate.mainWindowId(from: workspaceWindow))
        defer { _ = appDelegate.closeMainWindow(windowId: workspaceWindowID, recordHistory: false) }
        let workspaceContext = try #require(appDelegate.contextForMainTerminalWindow(workspaceWindow))
        let adoptedWorkspace = workspaceContext.tabManager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false
        )
        #expect(adoptedWorkspace.panels.values.contains { !($0 is BrowserPanel) })
        workspaceContext.tabManager.closeWorkspace(adoptedWorkspace, recordHistory: false)

        var workspaceCloseError: Error?
        workspaceAdapter.close(for: creatorContext) { workspaceCloseError = $0 }

        #expect(workspaceCloseError != nil)
        #expect(appDelegate.contextForMainTerminalWindow(workspaceWindow) != nil)
    }
}
