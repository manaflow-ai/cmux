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
@Suite("Main window close termination routing", .serialized)
struct MainWindowCloseTerminationRoutingTests {
    @Test("Stale disposable close callback cannot terminate the surviving window")
    func staleDisposableCloseCallbackCannotTerminateSurvivor() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
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
            TerminalController.shared.setActiveTabManager(nil)
            AppDelegate.shared = previousAppDelegate
        }

        #expect(closingController.windowShouldClose(closingWindow))
        #expect(app.commitMainWindowClose(closingWindow))
        #expect(app.mainWindowContexts.count == 1)

        let environmentKey = "XCTestConfigurationFilePath"
        let previousConfigurationPath = ProcessInfo.processInfo.environment[environmentKey]
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

        let shouldCloseStaleCandidate = closingController.windowShouldClose(closingWindow)

        #expect(shouldCloseStaleCandidate)
        #expect(ApplicationTerminateSpy.callCount == 0)
        #expect(app.mainWindowContexts.count == 1)
        #expect(app.tabManagerFor(windowId: survivorWindowId) === survivorManager)
        #expect(!survivorManager.isFinalizedForWindowClose)
        #expect(survivorManager.tabs.contains { $0 === survivorWorkspace })
        #expect(
            GhosttyApp.terminalSurfaceRegistry.surface(id: survivorTerminal.id)
                === survivorSurface
        )
    }
}
