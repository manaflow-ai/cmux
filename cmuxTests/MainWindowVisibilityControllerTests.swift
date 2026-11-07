import Testing
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MainWindowVisibilityControllerTests {

    @Test
    func focusDeminiaturizesAndActivatesThroughSingleOwner() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var miniaturizedWindows: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var activeWindows: [NSWindow] = []
        var deminiaturizedWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []
        var unhideCount = 0
        var appActivations: [NSApplication.ActivationOptions] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { activeWindows.append($0) },
                isApplicationHidden: { true },
                unhideApplication: { unhideCount += 1 },
                activateRunningApplication: { appActivations.append($0) },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { miniaturizedWindows.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedWindows.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKeyAndOrderFront: { madeKeyWindows.append($0) }
                )
            )
        )

        #expect(
            controller.focus(
                window,
                reason: .focusMainWindow,
                activation: .runningApplication([.activateAllWindows])
            )
        )
        #expect(activeWindows.first === window)
        #expect(deminiaturizedWindows.first === window)
        #expect(madeKeyWindows.first === window)
        #expect(unhideCount == 1)
        #expect(appActivations == [[.activateAllWindows]])
    }


    @Test
    func focusSuppressionOnlyUpdatesActiveContext() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var activeWindows: [NSWindow] = []
        var deminiaturizedCount = 0
        var madeKeyCount = 0
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { true },
                setActiveMainWindow: { activeWindows.append($0) },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { _ in true },
                    deminiaturize: { _ in deminiaturizedCount += 1 },
                    makeKeyAndOrderFront: { _ in madeKeyCount += 1 }
                )
            )
        )

        #expect(controller.focus(window, reason: .focusMainWindow))
        #expect(activeWindows.first === window)
        #expect(deminiaturizedCount == 0)
        #expect(madeKeyCount == 0)
        #expect(activationCount == 0)
    }


    @Test
    func hotkeyRestoreUsesCapturedVisibleTargetsWithoutDeminiaturizingMiniaturizedWindows() {
        let visibleWindow = makeWindow()
        let miniaturizedWindow = makeWindow()
        defer {
            visibleWindow.orderOut(nil)
            miniaturizedWindow.orderOut(nil)
        }

        let visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(visibleWindow)]
        var miniaturizedIds: Set<ObjectIdentifier> = [ObjectIdentifier(miniaturizedWindow)]
        var isAppActive = true
        var isAppHidden = false
        var hideCount = 0
        var unhideCount = 0
        var deminiaturizedWindows: [NSWindow] = [], madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationActive: { isAppActive },
                isApplicationHidden: { isAppHidden },
                hideApplication: {
                    hideCount += 1
                    isAppActive = false
                    isAppHidden = true
                },
                unhideApplication: {
                    unhideCount += 1
                    isAppHidden = false
                },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { miniaturizedIds.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedIds.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKey: { madeKeyWindows.append($0) }
                )
            )
        )

        controller.toggleApplicationVisibility(
            windows: [visibleWindow, miniaturizedWindow],
            reason: .globalHotkey
        )
        #expect(hideCount == 1)

        controller.toggleApplicationVisibility(
            windows: [visibleWindow, miniaturizedWindow],
            reason: .globalHotkey
        )

        #expect(unhideCount == 1)
        #expect(activationCount == 1)
        #expect(madeKeyWindows.contains { $0 === visibleWindow })
        #expect(!deminiaturizedWindows.contains { $0 === miniaturizedWindow })
    }


    @Test
    func showApplicationWindowsStillRestoresMiniaturizedWindowsWhenNoHiddenTargetsWereCaptured() {
        let miniaturizedWindow = makeWindow()
        defer { miniaturizedWindow.orderOut(nil) }

        var miniaturizedIds: Set<ObjectIdentifier> = [ObjectIdentifier(miniaturizedWindow)]
        var deminiaturizedWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { miniaturizedIds.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedIds.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKey: { madeKeyWindows.append($0) }
                )
            )
        )

        _ = controller.showApplicationWindows(windows: [miniaturizedWindow], reason: .globalHotkey)

        #expect(activationCount == 1)
        #expect(deminiaturizedWindows.contains { $0 === miniaturizedWindow })
        #expect(madeKeyWindows.contains { $0 === miniaturizedWindow })
    }


    @Test
    func dismissWindowsSoftHidesVisibleTargetsAndRestoresWithoutDeminiaturizing() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var softHiddenWindows: [NSWindow] = [], orderedRegardlessWindows: [NSWindow] = []
        var deminiaturizedWindows: [NSWindow] = [], madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { _ in false },
                    deminiaturize: { deminiaturizedWindows.append($0) },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) },
                    softHide: { softHiddenWindows.append($0) }
                )
            )
        )

        controller.dismissWindows(windows: [window], reason: .titlebarDismiss)
        _ = controller.showApplicationWindows(windows: [window], reason: .applicationReopen)

        #expect(softHiddenWindows.contains { $0 === window })
        #expect(orderedRegardlessWindows.contains { $0 === window })
        #expect(madeKeyWindows.contains { $0 === window })
        #expect(activationCount == 1)
        #expect(deminiaturizedWindows.isEmpty)
    }


    @Test
    func dismissedWindowDoesNotRestoreWhileAnotherWindowIsVisible() {
        let dismissedWindow = makeWindow()
        let visibleWindow = makeWindow()
        defer {
            dismissedWindow.orderOut(nil)
            visibleWindow.orderOut(nil)
        }

        var visibleIds: Set<ObjectIdentifier> = [
            ObjectIdentifier(dismissedWindow),
            ObjectIdentifier(visibleWindow)
        ]
        var madeKeyWindows: [NSWindow] = []
        var softHiddenWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    makeKey: { madeKeyWindows.append($0) },
                    softHide: { window in
                        visibleIds.remove(ObjectIdentifier(window))
                        softHiddenWindows.append(window)
                    }
                )
            )
        )

        controller.dismissWindows(
            windows: [dismissedWindow],
            reason: .titlebarDismiss
        )
        _ = controller.showApplicationWindows(
            windows: [dismissedWindow, visibleWindow],
            reason: .menuBar
        )

        #expect(softHiddenWindows.contains { $0 === dismissedWindow })
        #expect(madeKeyWindows.contains { $0 === visibleWindow })
        #expect(!madeKeyWindows.contains { $0 === dismissedWindow })
    }


    @Test
    func passiveRevealWithoutKeyTransferDoesNotActivateApplication() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var activationCount = 0
        var orderedRegardlessWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { _ in false },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) }
                )
            )
        )

        _ = controller.showApplicationWindows(
            windows: [window],
            reason: .applicationReopen,
            makeKey: false
        )

        #expect(
            activationCount == 0,
            "Ordering a visible cmux window without transferring key focus must not make cmux the Launch Services frontmost app."
        )
        #expect(orderedRegardlessWindows.contains { $0 === window })
        #expect(madeKeyWindows.isEmpty)
    }


    @Test
    func passiveRevealWithoutKeyTransferDoesNotDeminiaturizeWindow() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var miniaturizedIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var activationCount = 0
        var deminiaturizedWindows: [NSWindow] = []
        var orderedRegardlessWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { _ in false },
                    isMiniaturized: { miniaturizedIds.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedIds.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) }
                )
            )
        )

        let revealedWindow = controller.showApplicationWindows(
            windows: [window],
            reason: .applicationReopen,
            makeKey: false
        )

        #expect(
            revealedWindow == nil,
            "A passive reveal must not unminiaturize a background cmux window because AppKit can mark the app frontmost."
        )
        #expect(activationCount == 0)
        #expect(deminiaturizedWindows.isEmpty)
        #expect(orderedRegardlessWindows.isEmpty)
        #expect(madeKeyWindows.isEmpty)
    }


    @Test
    func hiddenAppRestoreFallsBackToSoftDismissedTargets() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var isAppHidden = false
        var unhideCount = 0
        var softShownWindows: [NSWindow] = [], madeKeyWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { isAppHidden },
                unhideApplication: {
                    unhideCount += 1
                    isAppHidden = false
                },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    makeKey: { madeKeyWindows.append($0) },
                    softHide: { visibleIds.remove(ObjectIdentifier($0)) },
                    softShow: { softShownWindows.append($0) }
                )
            )
        )

        controller.dismissWindows(windows: [window], reason: .titlebarDismiss)
        isAppHidden = true
        _ = controller.showApplicationWindows(windows: [window], reason: .applicationReopen)

        #expect(unhideCount == 1)
        #expect(softShownWindows.contains { $0 === window })
        #expect(madeKeyWindows.contains { $0 === window })
    }

#if DEBUG

    @Test
    func applicationReopenActivatesWhenRestoringBackgroundMainWindow() {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()

        let windowId = UUID()
        let window = makeWindow()
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        let tabManager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
            AppDelegate.shared = previousAppDelegate
        }

        var appActivations: [NSApplication.ActivationOptions] = []
        var madeKeyWindows: [NSWindow] = []
        var activeWindows: [NSWindow] = []
        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { activeWindows.append($0) },
                isApplicationHidden: { false },
                activateRunningApplication: { appActivations.append($0) },
                windowOperations: makeWindowOperations(
                    isVisible: { candidate in candidate === window },
                    isMiniaturized: { _ in false },
                    makeKey: { madeKeyWindows.append($0) }
                )
            )
        )
        app.replaceMainWindowVisibilityControllerForTesting(controller)

        #expect(app.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))

        #expect(appActivations == [[.activateAllWindows]])
        #expect(activeWindows.contains { $0 === window })
        #expect(madeKeyWindows.contains { $0 === window })
    }
#endif


    @Test
    func applicationActivationRestoreOrdersBeforeActivationThenMakesKeyAfterActivation() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var activeWindows: [NSWindow] = [], softShownWindows: [NSWindow] = []
        var orderedRegardlessWindows: [NSWindow] = [], madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { activeWindows.append($0) },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { _ in false },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) },
                    softHide: { visibleIds.remove(ObjectIdentifier($0)) },
                    softShow: { window in
                        visibleIds.insert(ObjectIdentifier(window))
                        softShownWindows.append(window)
                    }
                )
            )
        )

        controller.dismissWindows(windows: [window], reason: .titlebarDismiss)
        #expect(visibleIds.isEmpty)

        let preActivationWindow = controller.orderFrontApplicationWindowsBeforeActivation(
            windows: [window],
            reason: .applicationWillBecomeActive
        )
        #expect(preActivationWindow === window)
        #expect(activationCount == 0)
        #expect(orderedRegardlessWindows.contains { $0 === window })
        #expect(madeKeyWindows.isEmpty)

        let restoredWindow = controller.finishPendingApplicationActivationRestore(
            windows: [window],
            reason: .applicationDidBecomeActive
        )
        #expect(restoredWindow === window)
        #expect(activationCount == 0)
        #expect(activeWindows.filter { $0 === window }.count == 2)
        #expect(softShownWindows.filter { $0 === window }.count == 2)
        #expect(orderedRegardlessWindows.filter { $0 === window }.count == 2)
        #expect(madeKeyWindows.filter { $0 === window }.count == 1)
    }


    @Test
    func passiveActivationDoesNotRestoreOnlyMiniaturizedWindows() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var miniaturizedIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var deminiaturizedWindows: [NSWindow] = []
        var orderedRegardlessWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { miniaturizedIds.contains(ObjectIdentifier($0)) },
                    deminiaturize: { window in
                        miniaturizedIds.remove(ObjectIdentifier(window))
                        deminiaturizedWindows.append(window)
                    },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) }
                )
            )
        )

        #expect(
            controller.orderFrontApplicationWindowsBeforeActivation(
                windows: [window],
                reason: .applicationWillBecomeActive
            ) == nil
        )
        #expect(
            controller.restoreApplicationWindowsAfterActivation(
                windows: [window],
                reason: .applicationDidBecomeActive
            ) == nil
        )
        #expect(deminiaturizedWindows.isEmpty)
        #expect(orderedRegardlessWindows.isEmpty)
        #expect(madeKeyWindows.isEmpty)
        #expect(activationCount == 0)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeWindowOperations(
        isVisible: @escaping (NSWindow) -> Bool = { _ in true },
        isMiniaturized: @escaping (NSWindow) -> Bool = { _ in false },
        isKeyWindow: @escaping (NSWindow) -> Bool = { _ in false },
        canBecomeMain: @escaping (NSWindow) -> Bool = { _ in true },
        canBecomeKey: @escaping (NSWindow) -> Bool = { _ in true },
        deminiaturize: @escaping (NSWindow) -> Void = { _ in },
        makeKeyAndOrderFront: @escaping (NSWindow) -> Void = { _ in },
        makeKey: @escaping (NSWindow) -> Void = { _ in },
        orderFront: @escaping (NSWindow) -> Void = { _ in },
        orderFrontRegardless: @escaping (NSWindow) -> Void = { _ in },
        softHide: @escaping (NSWindow) -> Void = { _ in },
        softShow: @escaping (NSWindow) -> Void = { _ in }
    ) -> MainWindowVisibilityController.WindowOperations {
        MainWindowVisibilityController.WindowOperations(
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            isKeyWindow: isKeyWindow,
            canBecomeMain: canBecomeMain,
            canBecomeKey: canBecomeKey,
            deminiaturize: deminiaturize,
            makeKeyAndOrderFront: makeKeyAndOrderFront,
            makeKey: makeKey,
            orderFront: orderFront,
            orderFrontRegardless: orderFrontRegardless,
            orderOut: { _ in },
            softHide: softHide,
            softShow: softShow
        )
    }
}
