import AppKit
import ObjectiveC.runtime
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private enum ApplicationTerminateSpy {
    nonisolated(unsafe) static var callCount = 0

    static func install() throws {
        callCount = 0
        let originalSelector = #selector(NSApplication.terminate(_:))
        let spySelector = #selector(NSApplication.cmuxTestTerminate(_:))
        let applicationClass: AnyClass = NSApplication.self
        let originalMethod = try #require(
            class_getInstanceMethod(applicationClass, originalSelector)
        )
        let spyMethod = try #require(
            class_getInstanceMethod(applicationClass, spySelector)
        )
        method_exchangeImplementations(originalMethod, spyMethod)
    }

    static func uninstall() {
        let originalSelector = #selector(NSApplication.terminate(_:))
        let spySelector = #selector(NSApplication.cmuxTestTerminate(_:))
        let applicationClass: AnyClass = NSApplication.self
        guard let originalMethod = class_getInstanceMethod(applicationClass, originalSelector),
              let spyMethod = class_getInstanceMethod(applicationClass, spySelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, spyMethod)
    }
}

private extension NSApplication {
    @objc func cmuxTestTerminate(_ sender: Any?) {
        ApplicationTerminateSpy.callCount += 1
    }
}

@MainActor
private func evaluateCloseOutsideXCTest(
    _ body: () throws -> Bool
) throws -> (shouldClose: Bool, terminateCallCount: Int) {
    let environmentKey = "XCTestConfigurationFilePath"
    let previousConfigurationPath =
        ProcessInfo.processInfo.environment[environmentKey]
    unsetenv(environmentKey)
    defer {
        if let previousConfigurationPath {
            setenv(environmentKey, previousConfigurationPath, 1)
        } else {
            unsetenv(environmentKey)
        }
    }
    #expect(ProcessInfo.processInfo.environment[environmentKey] == nil)

    try ApplicationTerminateSpy.install()
    defer { ApplicationTerminateSpy.uninstall() }

    let shouldClose = try body()
    return (shouldClose, ApplicationTerminateSpy.callCount)
}

@MainActor
@Suite("Main window close termination routing", .serialized)
struct MainWindowCloseTerminationRoutingTests {
    @Test("Stale disposable close callback cannot terminate the surviving window")
    func staleDisposableCloseCallbackCannotTerminateSurvivor() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager =
            TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        AppDelegate.shared = app

        let survivorWindowId = app.createMainWindow(shouldActivate: false)
        let closingWindowId = app.createMainWindow(shouldActivate: false)
        let survivorManager = try #require(app.tabManagerFor(windowId: survivorWindowId))
        let survivorWorkspace = try #require(survivorManager.selectedWorkspace)
        let survivorTerminal = try #require(survivorWorkspace.focusedTerminalPanel)
        let survivorSurface = survivorTerminal.surface
        let closingWindow = try #require(app.windowForMainWindowId(closingWindowId))
        let closingController = try #require(closingWindow.delegate as? MainWindowController)

        defer {
            _ = app.closeMainWindow(windowId: closingWindowId, recordHistory: false)
            _ = app.closeMainWindow(windowId: survivorWindowId, recordHistory: false)
            closingWindow.delegate = nil
            closingWindow.orderOut(nil)
            closingWindow.close()
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        #expect(closingController.windowShouldClose(closingWindow))
        #expect(app.commitMainWindowClose(closingWindow))
        #expect(app.mainWindowContexts.count == 1)

        let result = try evaluateCloseOutsideXCTest {
            closingController.windowShouldClose(closingWindow)
        }

        #expect(result.shouldClose)
        #expect(result.terminateCallCount == 0)
        #expect(app.mainWindowContexts.count == 1)
        #expect(app.tabManagerFor(windowId: survivorWindowId) === survivorManager)
        #expect(!survivorManager.isFinalizedForWindowClose)
        #expect(survivorManager.tabs.contains { $0 === survivorWorkspace })
        #expect(
            GhosttyApp.terminalSurfaceRegistry.surface(id: survivorTerminal.id)
                === survivorSurface
        )
    }

    @Test("Unknown same-ID window cannot terminate the sole registered owner")
    func unknownSameIdWindowCannotTerminateRegisteredOwner() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager =
            TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        AppDelegate.shared = app

        let ownerWindowId = app.createMainWindow(shouldActivate: false)
        let ownerWindow = try #require(app.windowForMainWindowId(ownerWindowId))
        let ownerController = try #require(
            ownerWindow.delegate as? MainWindowController
        )
        let ownerManager = try #require(
            app.tabManagerFor(windowId: ownerWindowId)
        )
        let unknownWindow = NSWindow(
            contentRect: ownerWindow.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        unknownWindow.isReleasedWhenClosed = false
        unknownWindow.identifier = ownerWindow.identifier

        defer {
            _ = app.closeMainWindow(
                windowId: ownerWindowId,
                recordHistory: false
            )
            unknownWindow.orderOut(nil)
            unknownWindow.close()
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        let result = try evaluateCloseOutsideXCTest {
            ownerController.windowShouldClose(unknownWindow)
        }

        #expect(result.shouldClose)
        #expect(result.terminateCallCount == 0)
        #expect(app.tabManagerFor(windowId: ownerWindowId) === ownerManager)
        #expect(!ownerManager.isFinalizedForWindowClose)
    }

    @Test("Registered peer keeps a candidate close from becoming app quit")
    func registeredPeerPreventsCandidateCloseFromQuitting() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager =
            TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        AppDelegate.shared = app

        let candidateWindowId = app.createMainWindow(shouldActivate: false)
        let peerWindowId = app.createMainWindow(shouldActivate: false)
        let candidateWindow = try #require(
            app.windowForMainWindowId(candidateWindowId)
        )
        let candidateController = try #require(
            candidateWindow.delegate as? MainWindowController
        )
        let candidateManager = try #require(
            app.tabManagerFor(windowId: candidateWindowId)
        )
        let peerManager = try #require(
            app.tabManagerFor(windowId: peerWindowId)
        )

        defer {
            _ = app.closeMainWindow(
                windowId: peerWindowId,
                recordHistory: false
            )
            _ = app.closeMainWindow(
                windowId: candidateWindowId,
                recordHistory: false
            )
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        let result = try evaluateCloseOutsideXCTest {
            candidateController.windowShouldClose(candidateWindow)
        }

        #expect(result.shouldClose)
        #expect(result.terminateCallCount == 0)
        #expect(
            app.tabManagerFor(windowId: candidateWindowId)
                === candidateManager
        )
        #expect(app.tabManagerFor(windowId: peerWindowId) === peerManager)
    }

    @Test("Windowless recoverable peer keeps a candidate close from becoming app quit")
    func windowlessRecoverablePeerPreventsCandidateCloseFromQuitting() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager =
            TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        AppDelegate.shared = app

        let candidateWindowId = app.createMainWindow(shouldActivate: false)
        let candidateWindow = try #require(
            app.windowForMainWindowId(candidateWindowId)
        )
        let candidateController = try #require(
            candidateWindow.delegate as? MainWindowController
        )
        let recoverableWindowId = UUID()
        let recoverableManager = TabManager()
        let recoverableWorkspace = try #require(
            recoverableManager.selectedWorkspace
        )
        app.rememberRecoverableMainWindowRoute(
            windowId: recoverableWindowId,
            tabManager: recoverableManager,
            window: nil,
            sidebarSnapshot: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: 280
            )
        )

        defer {
            app.forgetRecoverableMainWindowRoute(
                windowId: recoverableWindowId
            )
            if !recoverableManager.isFinalizedForWindowClose {
                recoverableManager.finalizeAllWorkspacesForWindowClose()
            }
            recoverableWorkspace.teardownAllPanels()
            recoverableWorkspace.teardownRemoteConnection()
            _ = app.closeMainWindow(
                windowId: candidateWindowId,
                recordHistory: false
            )
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        #expect(
            app.mainWindowSessionPersistenceRoutes().contains {
                $0.windowId == recoverableWindowId
                    && $0.tabManager === recoverableManager
                    && $0.window == nil
            }
        )

        let result = try evaluateCloseOutsideXCTest {
            candidateController.windowShouldClose(candidateWindow)
        }

        #expect(result.shouldClose)
        #expect(result.terminateCallCount == 0)
        #expect(!recoverableManager.isFinalizedForWindowClose)
        #expect(
            app.mainWindowSessionPersistenceRoutes().contains {
                $0.windowId == recoverableWindowId
                    && $0.tabManager === recoverableManager
            }
        )
    }

    @Test("Compatibility recovery route retains and retires its supplied Dock")
    func compatibilityRecoveryRouteRetainsAndRetiresItsSuppliedDock() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        let windowId = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let dock = DockSplitStore(
            workspaceId: windowId,
            baseDirectoryProvider: { nil }
        )
        defer {
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            if !dock.isRetired {
                dock.retire()
            }
            AppDelegate.shared = previousAppDelegate
        }

        app.rememberRecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: manager,
            window: nil,
            sidebarSnapshot: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: 280
            ),
            windowDock: dock
        )

        #expect(app.existingWindowDock(forWindowId: windowId) === dock)

        app.forgetRecoverableMainWindowRoute(windowId: windowId)

        #expect(dock.isRetired)
        #expect(app.existingWindowDock(forWindowId: windowId) == nil)
    }

    @Test("Compatibility recovery route adopts a matching replacement context")
    func compatibilityRecoveryRouteAdoptsMatchingReplacementContext() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app

        let windowId = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let dock = DockSplitStore(
            workspaceId: windowId,
            baseDirectoryProvider: { nil }
        )
        let replacementWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        replacementWindow.isReleasedWhenClosed = false
        replacementWindow.identifier = NSUserInterfaceItemIdentifier(
            "cmux.main.\(windowId.uuidString)"
        )
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            app.forgetRecoverableMainWindowRoute(windowId: windowId)
            if !manager.isFinalizedForWindowClose {
                manager.finalizeAllWorkspacesForWindowClose()
            }
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            if !dock.isRetired {
                dock.retire()
            }
            replacementWindow.orderOut(nil)
            AppDelegate.shared = previousAppDelegate
        }

        app.rememberRecoverableMainWindowRoute(
            windowId: windowId,
            tabManager: manager,
            window: nil,
            sidebarSnapshot: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: 280
            ),
            windowDock: dock
        )

        app.registerMainWindow(
            replacementWindow,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        #expect(
            app.mainWindowContexts.values.contains {
                $0.windowId == windowId && $0.tabManager === manager
            }
        )
        #expect(app.recoverableMainWindowRoute(windowId: windowId) == nil)
        #expect(app.existingWindowDock(forWindowId: windowId) === dock)
        #expect(!dock.isRetired)
    }

    @Test("Exact sole owner retains last-window quit behavior")
    func exactSoleOwnerRetainsLastWindowQuitBehavior() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let previousActiveManager =
            TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        AppDelegate.shared = app

        let soleWindowId = app.createMainWindow(shouldActivate: false)
        let soleWindow = try #require(app.windowForMainWindowId(soleWindowId))
        let soleController = try #require(
            soleWindow.delegate as? MainWindowController
        )
        let soleManager = try #require(
            app.tabManagerFor(windowId: soleWindowId)
        )

        defer {
            _ = app.closeMainWindow(
                windowId: soleWindowId,
                recordHistory: false
            )
            TerminalController.shared.setActiveTabManager(previousActiveManager)
            AppDelegate.shared = previousAppDelegate
        }

        let result = try evaluateCloseOutsideXCTest {
            soleController.windowShouldClose(soleWindow)
        }

        #expect(!result.shouldClose)
        #expect(result.terminateCallCount == 1)
        #expect(app.tabManagerFor(windowId: soleWindowId) === soleManager)
        #expect(!soleManager.isFinalizedForWindowClose)
    }
}
