import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MainWindowVisibilityControllerTests: XCTestCase {
    func testFocusDeminiaturizesAndActivatesThroughSingleOwner() {
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

        XCTAssertTrue(
            controller.focus(
                window,
                reason: .focusMainWindow,
                activation: .runningApplication([.activateAllWindows])
            )
        )
        XCTAssertTrue(activeWindows.first === window)
        XCTAssertTrue(deminiaturizedWindows.first === window)
        XCTAssertTrue(madeKeyWindows.first === window)
        XCTAssertEqual(unhideCount, 1)
        XCTAssertEqual(appActivations, [[.activateAllWindows]])
    }

    func testFocusSuppressionOnlyUpdatesActiveContext() {
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

        XCTAssertTrue(controller.focus(window, reason: .focusMainWindow))
        XCTAssertTrue(activeWindows.first === window)
        XCTAssertEqual(deminiaturizedCount, 0)
        XCTAssertEqual(madeKeyCount, 0)
        XCTAssertEqual(activationCount, 0)
    }

    func testHotkeyRestoreUsesCapturedVisibleTargetsWithoutDeminiaturizingMiniaturizedWindows() {
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
        XCTAssertEqual(hideCount, 1)

        controller.toggleApplicationVisibility(
            windows: [visibleWindow, miniaturizedWindow],
            reason: .globalHotkey
        )

        XCTAssertEqual(unhideCount, 1)
        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(madeKeyWindows.contains { $0 === visibleWindow })
        XCTAssertFalse(deminiaturizedWindows.contains { $0 === miniaturizedWindow })
    }

    func testShowApplicationWindowsStillRestoresMiniaturizedWindowsWhenNoHiddenTargetsWereCaptured() {
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

        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(deminiaturizedWindows.contains { $0 === miniaturizedWindow })
        XCTAssertTrue(madeKeyWindows.contains { $0 === miniaturizedWindow })
    }

    func testDismissWindowsSoftHidesVisibleTargetsAndRestoresWithoutDeminiaturizing() {
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

        XCTAssertTrue(softHiddenWindows.contains { $0 === window })
        XCTAssertTrue(orderedRegardlessWindows.contains { $0 === window })
        XCTAssertTrue(madeKeyWindows.contains { $0 === window })
        XCTAssertEqual(activationCount, 1)
        XCTAssertTrue(deminiaturizedWindows.isEmpty)
    }

    func testDismissedWindowDoesNotRestoreWhileAnotherWindowIsVisible() {
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

        XCTAssertTrue(softHiddenWindows.contains { $0 === dismissedWindow })
        XCTAssertTrue(madeKeyWindows.contains { $0 === visibleWindow })
        XCTAssertFalse(madeKeyWindows.contains { $0 === dismissedWindow })
    }

    func testHiddenAppRestoreFallsBackToSoftDismissedTargets() {
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

        XCTAssertEqual(unhideCount, 1)
        XCTAssertTrue(softShownWindows.contains { $0 === window })
        XCTAssertTrue(madeKeyWindows.contains { $0 === window })
    }

    func testApplicationActivationRestoreOrdersBeforeActivationThenMakesKeyAfterActivation() {
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
        XCTAssertTrue(visibleIds.isEmpty)

        let preActivationWindow = controller.orderFrontApplicationWindowsBeforeActivation(
            windows: [window],
            reason: .applicationWillBecomeActive
        )
        XCTAssertTrue(preActivationWindow === window)
        XCTAssertEqual(activationCount, 0)
        XCTAssertTrue(orderedRegardlessWindows.contains { $0 === window })
        XCTAssertTrue(madeKeyWindows.isEmpty)

        let restoredWindow = controller.finishPendingApplicationActivationRestore(
            windows: [window],
            reason: .applicationDidBecomeActive
        )
        XCTAssertTrue(restoredWindow === window)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(activeWindows.filter { $0 === window }.count, 2)
        XCTAssertEqual(softShownWindows.filter { $0 === window }.count, 2)
        XCTAssertEqual(orderedRegardlessWindows.filter { $0 === window }.count, 2)
        XCTAssertEqual(madeKeyWindows.filter { $0 === window }.count, 1)
    }

    func testPassiveActivationDoesNotRestoreOnlyMiniaturizedWindows() {
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

        XCTAssertNil(
            controller.orderFrontApplicationWindowsBeforeActivation(
                windows: [window],
                reason: .applicationWillBecomeActive
            )
        )
        XCTAssertNil(
            controller.restoreApplicationWindowsAfterActivation(
                windows: [window],
                reason: .applicationDidBecomeActive
            )
        )
        XCTAssertTrue(deminiaturizedWindows.isEmpty)
        XCTAssertTrue(orderedRegardlessWindows.isEmpty)
        XCTAssertTrue(madeKeyWindows.isEmpty)
        XCTAssertEqual(activationCount, 0)
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
