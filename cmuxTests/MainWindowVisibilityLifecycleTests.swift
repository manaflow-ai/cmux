import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct MainWindowVisibilityLifecycleTests {
    @Test
    func discardClosedWindowRemovesHiddenRestoreTarget() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var softShownWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []
        var isAppHidden = true

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { isAppHidden },
                unhideApplication: { isAppHidden = false },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { _ in false },
                    makeKey: { madeKeyWindows.append($0) },
                    softShow: { softShownWindows.append($0) }
                )
            )
        )

        controller.captureHiddenWindowRestoreTargets(windows: [window], reason: .globalHotkey)
        controller.discardClosedWindow(window)

        #expect(controller.showApplicationWindows(windows: [window], reason: .applicationReopen) == nil)
        #expect(softShownWindows.isEmpty)
        #expect(madeKeyWindows.isEmpty)
    }

    @Test
    func discardClosedWindowRemovesDismissedRestoreTarget() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var softShownWindows: [NSWindow] = []
        var madeKeyWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { _ in false },
                    makeKey: { madeKeyWindows.append($0) },
                    softHide: { visibleIds.remove(ObjectIdentifier($0)) },
                    softShow: { softShownWindows.append($0) }
                )
            )
        )

        controller.dismissWindows(windows: [window], reason: .titlebarDismiss)
        controller.discardClosedWindow(window)

        #expect(controller.showApplicationWindows(windows: [window], reason: .applicationReopen) == nil)
        #expect(softShownWindows.isEmpty)
        #expect(madeKeyWindows.isEmpty)
    }

    @Test
    func discardClosedWindowClearsPendingActivationRestoreTarget() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var visibleIds: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var madeKeyWindows: [NSWindow] = []
        var orderedRegardlessWindows: [NSWindow] = []

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { _ in },
                isApplicationHidden: { false },
                windowOperations: makeWindowOperations(
                    isVisible: { visibleIds.contains(ObjectIdentifier($0)) },
                    isMiniaturized: { _ in false },
                    makeKey: { madeKeyWindows.append($0) },
                    orderFrontRegardless: { orderedRegardlessWindows.append($0) },
                    softHide: { visibleIds.remove(ObjectIdentifier($0)) }
                )
            )
        )

        controller.dismissWindows(windows: [window], reason: .titlebarDismiss)
        #expect(
            controller.orderFrontApplicationWindowsBeforeActivation(
                windows: [window],
                reason: .applicationWillBecomeActive
            ) === window
        )

        controller.discardClosedWindow(window)

        #expect(
            controller.finishPendingApplicationActivationRestore(
                windows: [window],
                reason: .applicationDidBecomeActive
            ) == nil
        )
        #expect(orderedRegardlessWindows.count == 1)
        #expect(madeKeyWindows.isEmpty)
    }

    @Test
    func committedCloseRejectsDirectFocusAndReveal() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var activeWindows: [NSWindow] = []
        var softShownWindows: [NSWindow] = []
        var orderedWindows: [NSWindow] = []
        var activationCount = 0

        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                setActiveMainWindow: { activeWindows.append($0) },
                activateRunningApplication: { _ in activationCount += 1 },
                windowOperations: makeWindowOperations(
                    makeKeyAndOrderFront: { orderedWindows.append($0) },
                    makeKey: { orderedWindows.append($0) },
                    orderFront: { orderedWindows.append($0) },
                    orderFrontRegardless: { orderedWindows.append($0) },
                    softShow: { softShownWindows.append($0) }
                )
            )
        )

        controller.commitClose(window)

        #expect(!controller.focus(window, reason: .focusMainWindow))
        controller.focusForInWindowCommand(window, reason: .findShortcut)
        #expect(
            controller.reveal(
                [window],
                preferredWindow: window,
                reason: .applicationReopen
            ) == nil
        )
        #expect(activeWindows.isEmpty)
        #expect(softShownWindows.isEmpty)
        #expect(orderedWindows.isEmpty)
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
