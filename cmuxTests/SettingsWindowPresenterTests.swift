import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite(.serialized)
struct SettingsWindowPresenterTests {
    @Test func configureWindowLeavesPendingNavigationForSettingsViews() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let settingsWindow = makeWindow(identifier: "cmux.unconfiguredSettings.\(UUID().uuidString)")
            var didOpen = false
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.close()
            }

            presenter.show(
                navigationTarget: .browserImport,
                openWindowOverride: { didOpen = true }
            )
            presenter.configure(window: settingsWindow)

            #expect(didOpen)
            #expect(presenter.consumePendingNavigationTarget() == .browserImport)
            #expect(presenter.consumePendingContentNavigationTarget() == .browserImport)
            #expect(presenter.consumePendingNavigationTarget() == nil)
            #expect(presenter.consumePendingContentNavigationTarget() == nil)
        }
    }

    @Test func repeatedConfigureForSameSettingsWindowDoesNotRefocus() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.close()
            }

            presenter.show(openWindowOverride: {})
            presenter.configure(window: settingsWindow)
            await Task.yield()
            presenter.configure(window: settingsWindow)
            await Task.yield()

            #expect(settingsWindow.makeKeyAndOrderFrontCallCount == 1)
        }
    }

    @Test func configureWindowWithoutOpenRequestDoesNotFocus() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.close()
            }

            presenter.configure(window: settingsWindow)
            await Task.yield()

            #expect(settingsWindow.makeKeyAndOrderFrontCallCount == 0)
            #expect(!settingsWindow.isVisible)
        }
    }

    @Test func showPreservesPendingNavigationWhenExistingSettingsWindowIsMiniaturized() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let settingsWindow = makeWindow(
                identifier: SettingsWindowPresenter.windowIdentifier,
                forcedMiniaturized: true
            )
            var didOpen = false
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.close()
            }

            presenter.configure(window: settingsWindow)
            await Task.yield()

            presenter.show(
                navigationTarget: .browserImport,
                openWindowOverride: { didOpen = true }
            )

            #expect(!didOpen)
            #expect(presenter.consumePendingNavigationTarget() == .browserImport)
            #expect(presenter.consumePendingContentNavigationTarget() == .browserImport)
        }
    }

    @Test func closedSettingsWindowReopensThroughSceneInsteadOfRetainingHiddenTree() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            var didOpen = false
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.close()
            }

            presenter.show(openWindowOverride: {})
            presenter.configure(window: settingsWindow)
            await Task.yield()
            #expect(settingsWindow.makeKeyAndOrderFrontCallCount == 1)

            settingsWindow.close()
            await Task.yield()

            presenter.show(
                openWindowOverride: { didOpen = true }
            )

            #expect(didOpen)
            #expect(settingsWindow.makeKeyAndOrderFrontCallCount == 1)
        }
    }

    @Test func showReusesTrackedOrderedOutSettingsWindow() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            var didOpen = false
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.close()
            }

            presenter.configure(window: settingsWindow)
            settingsWindow.orderOut(nil)
            await Task.yield()

            presenter.show(openWindowOverride: { didOpen = true })

            #expect(!didOpen)
            #expect(settingsWindow.makeKeyAndOrderFrontCallCount == 1)
            #expect(settingsWindow.isVisible)
        }
    }

    @Test func repeatedShowWhileSettingsSceneIsOpeningCoalescesOpenRequests() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            var openCallCount = 0

            presenter.show(openWindowOverride: { openCallCount += 1 })
            presenter.show(openWindowOverride: { openCallCount += 1 })

            #expect(openCallCount == 1)
        }
    }

    @Test func refocusIfVisibleDoesNotReopenClosedSettingsWindow() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.close()
            }

            presenter.show(openWindowOverride: {})
            presenter.configure(window: settingsWindow)
            await Task.yield()
            #expect(settingsWindow.makeKeyAndOrderFrontCallCount == 1)

            settingsWindow.orderOut(nil)
            #expect(!settingsWindow.isVisible)

            presenter.refocusIfVisible()

            #expect(settingsWindow.makeKeyAndOrderFrontCallCount == 1)
            #expect(!settingsWindow.isVisible)
        }
    }

    @Test func doesNotAttachSettingsAsChildOfPreferredMainWindow() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let parentWindow = makeWindow(identifier: "cmux.main.\(UUID().uuidString)")
            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            defer {
                settingsWindow.orderOut(nil)
                parentWindow.orderOut(nil)
                settingsWindow.close()
                parentWindow.close()
            }

            presenter.configure(
                openWindow: {},
                parentWindowProvider: { parentWindow }
            )
            presenter.configure(window: settingsWindow)

            #expect(settingsWindow.parent == nil)
            #expect(!hasChild(parentWindow, settingsWindow))
            #expect(settingsWindow.level == .normal)
        }
    }

    @Test func focusingSettingsKeepsItAsPeerWhenPreferredMainWindowChanges() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let firstParent = makeWindow(identifier: "cmux.main.\(UUID().uuidString)")
            let secondParent = makeWindow(identifier: "cmux.main.\(UUID().uuidString)")
            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            var preferredParent = firstParent
            defer {
                settingsWindow.orderOut(nil)
                firstParent.orderOut(nil)
                secondParent.orderOut(nil)
                settingsWindow.close()
                firstParent.close()
                secondParent.close()
            }

            presenter.configure(
                openWindow: {},
                parentWindowProvider: { preferredParent }
            )
            presenter.configure(window: settingsWindow)
            #expect(settingsWindow.parent == nil)

            preferredParent = secondParent
            settingsWindow.orderFront(nil)
            presenter.refocusIfVisible()

            #expect(settingsWindow.parent == nil)
            #expect(!hasChild(firstParent, settingsWindow))
            #expect(!hasChild(secondParent, settingsWindow))
            #expect(settingsWindow.level == .normal)
        }
    }

    @Test func settingsSurvivesPreferredMainWindowCloseAsIndependentPeer() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let parentWindow = makeWindow(identifier: "cmux.main.\(UUID().uuidString)")
            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            defer {
                settingsWindow.orderOut(nil)
                parentWindow.orderOut(nil)
                settingsWindow.close()
                parentWindow.close()
            }

            presenter.configure(
                openWindow: {},
                parentWindowProvider: { parentWindow }
            )
            presenter.configure(window: settingsWindow)
            settingsWindow.orderFront(nil)
            #expect(settingsWindow.parent == nil)

            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: parentWindow)

            #expect(settingsWindow.parent == nil)
            #expect(settingsWindow.isVisible)
        }
    }

    @Test func adoptCmuxPeerWindowLevelBringsFloatingWindowToNormal() async throws {
        try await withCleanSettingsWindows {
            let window = makeWindow(identifier: "cmux.peer.\(UUID().uuidString)")
            defer {
                window.orderOut(nil)
                window.close()
            }

            window.level = .floating
            #expect(window.level == .floating)

            window.adoptCmuxPeerWindowLevel()

            #expect(window.level == .normal)
        }
    }

    @Test func configureClampsOversizedSettingsFrameToVisibleArea() async throws {
        try await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            let screen = try #require(NSScreen.main)
            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            let visibleFrame = screen.visibleFrame
            settingsWindow.setFrame(
                NSRect(
                    x: visibleFrame.minX - 120,
                    y: visibleFrame.minY - 120,
                    width: visibleFrame.width * 2,
                    height: visibleFrame.height * 2
                ),
                display: false
            )
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.close()
            }

            presenter.configure(window: settingsWindow)

            let inset: CGFloat = 18
            let availableWidth = max(
                SettingsWindowPresenter.minimumSize.width,
                visibleFrame.width - 2 * inset
            )
            let availableHeight = max(
                SettingsWindowPresenter.minimumSize.height,
                visibleFrame.height - 2 * inset
            )
            let frame = settingsWindow.frame
            #expect(frame.width <= availableWidth)
            #expect(frame.height <= availableHeight)
            #expect(frame.minX >= visibleFrame.minX + inset)
            #expect(frame.minY >= visibleFrame.minY + inset)
            if frame.width <= visibleFrame.width - 2 * inset {
                #expect(frame.maxX <= visibleFrame.maxX - inset)
            }
            if frame.height <= visibleFrame.height - 2 * inset {
                #expect(frame.maxY <= visibleFrame.maxY - inset)
            }
        }
    }

    private func withCleanSettingsWindows(_ body: () async throws -> Void) async rethrows {
        closeSettingsWindows()
        defer { closeSettingsWindows() }
        try await body()
    }

    private func makeWindow(
        identifier: String,
        forcedMiniaturized: Bool? = nil
    ) -> TestSettingsWindow {
        let window = TestSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.forcedMiniaturized = forcedMiniaturized
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        return window
    }

    private func closeSettingsWindows() {
        for window in NSApp.windows where window.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier {
            window.orderOut(nil)
            window.identifier = nil
            window.close()
        }
    }

    private func hasChild(_ parentWindow: NSWindow, _ childWindow: NSWindow) -> Bool {
        parentWindow.childWindows?.contains { $0 === childWindow } == true
    }

    private final class TestSettingsWindow: NSWindow {
        var forcedMiniaturized: Bool?
        var makeKeyAndOrderFrontCallCount = 0

        override var isMiniaturized: Bool {
            forcedMiniaturized ?? super.isMiniaturized
        }

        override func makeKeyAndOrderFront(_ sender: Any?) {
            makeKeyAndOrderFrontCallCount += 1
            super.makeKeyAndOrderFront(sender)
        }
    }
}
#endif
