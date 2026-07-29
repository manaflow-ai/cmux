import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Main window availability")
struct MainWindowAvailabilityTests {
    @Test
    func focusUnavailableWindowRejectsAllMutationsAndRecordsOwnership() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let windowId = UUID()
        let workspaceId = UUID()
        var activeCount = 0
        var windowMutationCount = 0
        var activationCount = 0
        var breadcrumbs: [String: [String: Any]] = [:]
        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                windowAvailability: { _ in
                    .init(
                        isAvailable: false,
                        windowId: windowId,
                        workspaceId: workspaceId,
                        owner: "missing"
                    )
                },
                setActiveMainWindow: { _ in activeCount += 1 },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in activationCount += 1 },
                recordBreadcrumb: { message, data in breadcrumbs[message] = data },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { _ in true },
                    deminiaturize: { _ in windowMutationCount += 1 },
                    makeKeyAndOrderFront: { _ in windowMutationCount += 1 },
                    orderFront: { _ in windowMutationCount += 1 },
                    softShow: { _ in windowMutationCount += 1 }
                )
            )
        )

        #expect(!controller.focus(window, reason: .focusMainWindow))
        #expect(activeCount == 0)
        #expect(windowMutationCount == 0)
        #expect(activationCount == 0)
        #expect(
            breadcrumbs["mainWindow.focus.unavailable"]?["reason"] as? String
                == "focusMainWindow"
        )
        #expect(
            breadcrumbs["mainWindow.focus.unavailable"]?["windowId"] as? String
                == windowId.uuidString
        )
        #expect(
            breadcrumbs["mainWindow.focus.unavailable"]?["workspaceId"] as? String
                == workspaceId.uuidString
        )
        #expect(
            breadcrumbs["mainWindow.focus.unavailable"]?["windowAvailable"] as? Bool
                == false
        )
        #expect(
            breadcrumbs["mainWindow.focus.unavailable"]?["owner"] as? String
                == "missing"
        )
    }

    @Test
    func focusUnavailableWindowWinsOverSuppression() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var activeCount = 0
        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { true },
                windowAvailability: { _ in
                    .init(
                        isAvailable: false,
                        windowId: nil,
                        workspaceId: nil,
                        owner: "missing"
                    )
                },
                setActiveMainWindow: { _ in activeCount += 1 }
            )
        )

        #expect(!controller.focus(window, reason: .focusMainWindow))
        #expect(activeCount == 0)
    }

    @Test
    func inWindowCommandRejectsUnavailableWindow() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var mutationCount = 0
        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                windowAvailability: { _ in
                    .init(
                        isAvailable: false,
                        windowId: nil,
                        workspaceId: nil,
                        owner: "close-committed"
                    )
                },
                setActiveMainWindow: { _ in mutationCount += 1 },
                isApplicationHidden: { true },
                unhideApplication: { mutationCount += 1 },
                activateRunningApplication: { _ in mutationCount += 1 },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { _ in true },
                    deminiaturize: { _ in mutationCount += 1 },
                    makeKeyAndOrderFront: { _ in mutationCount += 1 },
                    softShow: { _ in mutationCount += 1 }
                )
            )
        )

        #expect(!controller.focusForInWindowCommand(window, reason: .findShortcut))
        #expect(mutationCount == 0)
    }

    @Test
    func showApplicationWindowsRejectsUnavailableWindowBeforeUnhiding() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var mutationCount = 0
        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                windowAvailability: { _ in
                    .init(
                        isAvailable: false,
                        windowId: nil,
                        workspaceId: nil,
                        owner: "close-committed"
                    )
                },
                setActiveMainWindow: { _ in mutationCount += 1 },
                isApplicationHidden: { true },
                unhideApplication: { mutationCount += 1 },
                activateRunningApplication: { _ in mutationCount += 1 },
                windowOperations: makeWindowOperations(
                    isMiniaturized: { _ in true },
                    deminiaturize: { _ in mutationCount += 1 },
                    makeKey: { _ in mutationCount += 1 },
                    orderFrontRegardless: { _ in mutationCount += 1 },
                    softShow: { _ in mutationCount += 1 }
                )
            )
        )

        #expect(controller.showApplicationWindows(
            windows: [window],
            reason: .globalHotkey
        ) == nil)
        #expect(mutationCount == 0)
    }

    @Test
    func hotkeyDoesNotHideUnavailableVisibleWindow() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        var hideCount = 0
        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                windowAvailability: { _ in
                    .init(
                        isAvailable: false,
                        windowId: nil,
                        workspaceId: nil,
                        owner: "close-committed"
                    )
                },
                setActiveMainWindow: { _ in },
                isApplicationActive: { true },
                isApplicationHidden: { false },
                hideApplication: { hideCount += 1 },
                windowOperations: makeWindowOperations(
                    isVisible: { _ in true },
                    isMiniaturized: { _ in false }
                )
            )
        )

        controller.toggleApplicationVisibility(windows: [window], reason: .globalHotkey)
        #expect(hideCount == 0)
    }

    @Test
    func revealFiltersUnavailableWindowsAtOrderingBoundary() {
        let unavailableWindow = makeWindow()
        let availableWindow = makeWindow()
        defer {
            unavailableWindow.orderOut(nil)
            availableWindow.orderOut(nil)
        }

        var mutatedWindows: [NSWindow] = []
        var activeWindows: [NSWindow] = []
        let controller = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { false },
                windowAvailability: { window in
                    .init(
                        isAvailable: window === availableWindow,
                        windowId: nil,
                        workspaceId: nil,
                        owner: window === availableWindow
                            ? "registered-context"
                            : "close-committed"
                    )
                },
                setActiveMainWindow: { activeWindows.append($0) },
                isApplicationHidden: { false },
                activateRunningApplication: { _ in },
                windowOperations: makeWindowOperations(
                    makeKey: { mutatedWindows.append($0) },
                    orderFrontRegardless: { mutatedWindows.append($0) },
                    softShow: { mutatedWindows.append($0) }
                )
            )
        )

        let revealed = controller.reveal(
            [unavailableWindow, availableWindow],
            preferredWindow: unavailableWindow,
            reason: .menuBar
        )

        #expect(revealed === availableWindow)
        #expect(activeWindows.allSatisfy { $0 === availableWindow })
        #expect(mutatedWindows.allSatisfy { $0 === availableWindow })
        #expect(!mutatedWindows.isEmpty)
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
        deminiaturize: @escaping (NSWindow) -> Void = { _ in },
        makeKeyAndOrderFront: @escaping (NSWindow) -> Void = { _ in },
        makeKey: @escaping (NSWindow) -> Void = { _ in },
        orderFront: @escaping (NSWindow) -> Void = { _ in },
        orderFrontRegardless: @escaping (NSWindow) -> Void = { _ in },
        softShow: @escaping (NSWindow) -> Void = { _ in }
    ) -> MainWindowVisibilityController.WindowOperations {
        MainWindowVisibilityController.WindowOperations(
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            isKeyWindow: { _ in false },
            canBecomeMain: { _ in true },
            canBecomeKey: { _ in true },
            deminiaturize: deminiaturize,
            makeKeyAndOrderFront: makeKeyAndOrderFront,
            makeKey: makeKey,
            orderFront: orderFront,
            orderFrontRegardless: orderFrontRegardless,
            orderOut: { _ in },
            softHide: { _ in },
            softShow: softShow
        )
    }
}
