import AppKit
import CmuxSettingsUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
/// Serialized umbrella for every suite that mutates process-global Settings
/// window state: NSApp's window list (each suite enumerates and closes all
/// `cmux.settings` windows) and the shared `NSWindow Frame cmux.settings`
/// autosave slot. `.serialized` applies recursively, so the member suites run
/// serially against each other; as sibling top-level suites they could
/// interleave at await points and tear down each other's windows mid-test.
@Suite(.serialized)
enum SettingsWindowSharedStateSuites {}

extension SettingsWindowSharedStateSuites {
    /// Unit coverage for ``SettingsWindowPresenter``'s AppKit-owned lifecycle
    /// (issue #7777) using an injected window factory. End-to-end coverage of the
    /// real factory path lives in `SettingsWindowOpenRegressionTests`.
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowPresenterTests {
        // MARK: - Creation, reuse, and self-healing

        @Test func showCreatesWindowThroughFactoryAndFrontsIt() {
            withCleanSettingsWindows {
                var factoryCallCount = 0
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    factoryCallCount += 1
                    return makeFactoryWindow()
                })

                let result = presenter.show()

                #expect(result == .presented)
                #expect(factoryCallCount == 1)
                let window = visibleSettingsWindow()
                #expect(window != nil)
                #expect(window?.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier)
                #expect(window?.isReleasedWhenClosed == false)
                #expect(window?.isRestorable == false)
            }
        }

        @Test func showReusesUsableExistingWindow() {
            withCleanSettingsWindows {
                var factoryCallCount = 0
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    factoryCallCount += 1
                    return makeFactoryWindow()
                })

                #expect(presenter.show() == .presented)
                #expect(presenter.show() == .presented)

                #expect(factoryCallCount == 1)
            }
        }

        @Test func showAfterCloseCreatesFreshWindow() {
            withCleanSettingsWindows {
                var factoryCallCount = 0
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    factoryCallCount += 1
                    return makeFactoryWindow()
                })

                #expect(presenter.show() == .presented)
                let firstWindow = visibleSettingsWindow()
                firstWindow?.close()

                #expect(presenter.show() == .presented)

                #expect(factoryCallCount == 2)
                // The closed window must never satisfy a future open request.
                #expect(firstWindow?.identifier == nil)
                let secondWindow = visibleSettingsWindow()
                #expect(secondWindow != nil)
                #expect(secondWindow !== firstWindow)
            }
        }

        @Test func closingRetiresTheWholeWindowWithoutDismantlingContent() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makeFactoryWindow() })

                #expect(presenter.show() == .presented)
                let window = visibleSettingsWindow()
                #expect(window?.contentViewController != nil)

                window?.close()

                // Retire the complete graph. Clearing hosted content from a
                // willClose callback can race AppKit/SwiftUI teardown; the
                // presenter instead drops identity and ownership so this
                // externally-retained window remains internally consistent.
                #expect(window?.identifier == nil)
                #expect(window?.contentViewController != nil)
            }
        }

        @Test func showTearsDownContentlessWindowAndRecreates() {
            withCleanSettingsWindows {
                var factoryCallCount = 0
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    factoryCallCount += 1
                    return makeFactoryWindow()
                })

                #expect(presenter.show() == .presented)
                let huskWindow = visibleSettingsWindow()
                // Simulate a window whose content was torn down without a close
                // (the "hidden-but-alive" / unloaded-content family).
                huskWindow?.contentViewController = nil
                huskWindow?.contentView = nil

                #expect(presenter.show() == .presented)

                #expect(factoryCallCount == 2)
                #expect(huskWindow?.identifier == nil)
                let replacement = visibleSettingsWindow()
                #expect(replacement != nil)
                #expect(replacement !== huskWindow)
            }
        }

        @Test func showDuringWillCloseCreatesFreshWindow() {
            withCleanSettingsWindows {
                var factoryCallCount = 0
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    factoryCallCount += 1
                    return makeFactoryWindow()
                })

                #expect(presenter.show() == .presented)
                let firstWindow = visibleSettingsWindow()
                #expect(firstWindow != nil)
                guard let firstWindow else { return }

                var midCloseResult: SettingsWindowShowResult?
                let reopener = ReopenSettingsOnWillClose(window: firstWindow) {
                    midCloseResult = presenter.show()
                }
                firstWindow.close()
                reopener.stopObserving()

                #expect(midCloseResult == .presented)
                #expect(factoryCallCount == 2)
                #expect(visibleSettingsWindow() != nil)
            }
        }

        @Test func showFailsLoudlyWhenNoWindowBecomesVisible() {
            withCleanSettingsWindows {
                var factoryCallCount = 0
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    factoryCallCount += 1
                    let window = makeFactoryWindow()
                    window.refusesToBecomeVisible = true
                    return window
                })

                let result = presenter.show()

                // Bounded recreation: one reuse-or-create pass plus one fresh
                // recreate, then a loud failure — never a silent no-op.
                #expect(factoryCallCount == SettingsWindowPresenter.maxPresentAttempts)
                guard case .failed(let reason) = result else {
                    Issue.record("expected .failed, got \(result)")
                    return
                }
                #expect(reason.contains("did not become visible"))
            }
        }

        @Test func showWithoutActivationPresentsWithoutKeyingTheWindow() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makeFactoryWindow() })

                let result = presenter.show(activateApp: false)

                // Socket no-focus-steal contract: the window becomes visible but
                // is never made key and the app is not activated.
                #expect(result == .presented)
                let window = visibleSettingsWindow() as? TestSettingsWindow
                #expect(window != nil)
                #expect(window?.makeKeyAndOrderFrontCallCount == 0)
            }
        }

        @Test func hostWindowRecordsCloseBeginForMidCloseRejection() {
            withCleanSettingsWindows {
                let window = makeFactoryWindow()
                #expect(!window.isClosingSettingsWindow)

                window.close()

                // The flag is what lets show() deterministically refuse a dying
                // window regardless of notification-observer order.
                #expect(window.isClosingSettingsWindow)
            }
        }

        @Test func repeatedOpenResizeToggleCloseDoesNotLeakOrWedge() async throws {
            closeSettingsWindows()
            defer { closeSettingsWindows() }

            let inset = SettingsWindowPresenter.visibleAreaInset
            let referenceVisibleFrame = try #require(
                (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            )
            let smallFactoryFrame = NSRect(x: 0, y: 0, width: 500, height: 300)
            let largeFactoryFrame = NSRect(
                x: referenceVisibleFrame.minX - 120,
                y: referenceVisibleFrame.minY - 120,
                width: referenceVisibleFrame.width * 2,
                height: referenceVisibleFrame.height * 2
            )
            var requestedFactoryFrame = smallFactoryFrame
            var expectedVisibleFrame = referenceVisibleFrame
            var factoryCallCount = 0
            let presenter = SettingsWindowPresenter(windowFactory: { _ in
                factoryCallCount += 1
                let window = makeFactoryWindow(contentRect: requestedFactoryFrame)
                window.factoryToken = factoryCallCount
                window.toolbar = window.sidebarToolbarController.makeToolbar()
                return window
            })
            let toggleRecorder = SettingsSidebarToggleRecorder()
            defer { toggleRecorder.stopObserving() }
            var seenFactoryTokens: Set<Int> = []
            var expectedRestoredFrame: NSRect?
            var retiredWindows: [WeakSettingsWindowBox] = []

            for cycle in 0..<100 {
                let shouldRestorePreviousFrame = !cycle.isMultiple(of: 2)
                if !shouldRestorePreviousFrame {
                    UserDefaults.standard.removeObject(forKey: "NSWindow Frame cmux.settings")
                    requestedFactoryFrame = cycle.isMultiple(of: 4)
                        ? smallFactoryFrame
                        : largeFactoryFrame
                    expectedVisibleFrame = try #require(
                        SettingsWindowPresenter.targetVisibleFrame(
                            windowFrame: requestedFactoryFrame,
                            screens: NSScreen.screens.map {
                                (frame: $0.frame, visibleFrame: $0.visibleFrame)
                            },
                            mouseLocation: NSEvent.mouseLocation,
                            fallbackVisibleFrame: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                        )
                    )
                }

                #expect(presenter.show() == .presented)
                #expect(await waitUntil { visibleSettingsWindows().count == 1 })

                let retiredWindow = try autoreleasepool {
                    let window = try #require(visibleSettingsWindow() as? TestSettingsWindow)
                    let availableWidth = max(
                        SettingsWindowPresenter.minimumSize.width,
                        expectedVisibleFrame.width - 2 * inset
                    )
                    let availableHeight = max(
                        SettingsWindowPresenter.minimumSize.height,
                        expectedVisibleFrame.height - 2 * inset
                    )
                    #expect(window.factoryToken == cycle + 1)
                    #expect(seenFactoryTokens.insert(window.factoryToken).inserted)
                    #expect(window.contentViewController != nil || window.contentView != nil)
                    #expect(window.frame.width >= SettingsWindowPresenter.minimumSize.width)
                    #expect(window.frame.height >= SettingsWindowPresenter.minimumSize.height)
                    #expect(window.frame.width <= availableWidth)
                    #expect(window.frame.height <= availableHeight)
                    #expect(window.frame.minX >= expectedVisibleFrame.minX + inset)
                    #expect(window.frame.minY >= expectedVisibleFrame.minY + inset)
                    #expect(window.frame.maxX <= expectedVisibleFrame.maxX - inset)
                    #expect(window.frame.maxY <= expectedVisibleFrame.maxY - inset)
                    if shouldRestorePreviousFrame {
                        let restoredFrame = try #require(expectedRestoredFrame)
                        #expect(abs(window.frame.minX - restoredFrame.minX) < 1)
                        #expect(abs(window.frame.minY - restoredFrame.minY) < 1)
                        #expect(abs(window.frame.width - restoredFrame.width) < 1)
                        #expect(abs(window.frame.height - restoredFrame.height) < 1)
                    }

                    let resizedWidth = min(
                        availableWidth,
                        SettingsWindowPresenter.minimumSize.width + CGFloat(cycle % 7) * 20
                    )
                    let resizedHeight = min(
                        availableHeight,
                        SettingsWindowPresenter.minimumSize.height + CGFloat(cycle % 5) * 20
                    )
                    window.setFrame(
                        NSRect(
                            x: expectedVisibleFrame.midX - resizedWidth / 2,
                            y: expectedVisibleFrame.midY - resizedHeight / 2,
                            width: resizedWidth,
                            height: resizedHeight
                        ),
                        display: false
                    )
                    #expect(window.frame.width == resizedWidth)
                    #expect(window.frame.height == resizedHeight)
                    window.saveFrame(usingName: SettingsWindowPresenter.windowIdentifier)
                    expectedRestoredFrame = window.frame

                    #expect(presenter.show() == .presented)
                    #expect(visibleSettingsWindows().count == 1)
                    #expect(visibleSettingsWindow() === window)

                    let toggleItem = try #require(
                        window.toolbar?.items.first {
                            $0.itemIdentifier == SettingsSidebarToolbarController.toggleSidebarItemIdentifier
                        }
                    )
                    let action = try #require(toggleItem.action)
                    #expect(NSApp.sendAction(action, to: toggleItem.target, from: toggleItem))
                    #expect(toggleRecorder.receivedCount == cycle + 1)

                    let weakWindow = WeakSettingsWindowBox(window)
                    window.close()
                    #expect(window.identifier == nil)
                    return weakWindow
                }
                retiredWindows.append(retiredWindow)

                #expect(await waitUntil {
                    visibleSettingsWindows().isEmpty
                        && retiredWindows.allSatisfy { $0.window == nil }
                })
                #expect(retiredWindows.compactMap(\.window).isEmpty)
            }

            #expect(factoryCallCount == 100)
            #expect(toggleRecorder.receivedCount == 100)
        }

        // MARK: - Geometry repair on show

        @Test func showEnforcesMinimumSizeOnDegenerateFactoryWindow() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    makeFactoryWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300))
                })

                #expect(presenter.show() == .presented)

                let frame = visibleSettingsWindow()?.frame
                #expect((frame?.width ?? 0) >= SettingsWindowPresenter.minimumSize.width)
                #expect((frame?.height ?? 0) >= SettingsWindowPresenter.minimumSize.height)
            }
        }

        @Test func showClampsOversizedSettingsFrameToVisibleArea() throws {
            try withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makeFactoryWindow() })
                let screen = try #require(NSScreen.main)
                let visibleFrame = screen.visibleFrame

                #expect(presenter.show() == .presented)
                let window = try #require(visibleSettingsWindow())
                window.setFrame(
                    NSRect(
                        x: visibleFrame.minX - 120,
                        y: visibleFrame.minY - 120,
                        width: visibleFrame.width * 2,
                        height: visibleFrame.height * 2
                    ),
                    display: false
                )

                #expect(presenter.show() == .presented)

                let inset: CGFloat = 18
                let availableWidth = max(
                    SettingsWindowPresenter.minimumSize.width,
                    visibleFrame.width - 2 * inset
                )
                let availableHeight = max(
                    SettingsWindowPresenter.minimumSize.height,
                    visibleFrame.height - 2 * inset
                )
                let frame = window.frame
                #expect(frame.width <= availableWidth)
                #expect(frame.height <= availableHeight)
                #expect(frame.minX >= visibleFrame.minX + inset)
                #expect(frame.minY >= visibleFrame.minY + inset)
            }
        }

        // MARK: - Navigation delivery

        @Test func navigationPostsImmediatelyForReadyExistingWindow() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makeFactoryWindow() })
                #expect(presenter.show() == .presented)
                // The content signals readiness from the host root's onAppear.
                presenter.deliverPendingNavigationAfterContentAppears()

                let recorder = SettingsNavigationRecorder()
                #expect(presenter.show(navigationTarget: .browserImport) == .presented)
                recorder.stopObserving()

                #expect(recorder.receivedTargets == [.browserImport])
                // Delivered immediately, so nothing stays pending.
                #expect(presenter.consumePendingNavigationTarget() == nil)
            }
        }

        @Test func navigationStaysPendingForFreshWindowUntilContentConsumesIt() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makeFactoryWindow() })

                let recorder = SettingsNavigationRecorder()
                #expect(presenter.show(navigationTarget: .browserImport) == .presented)
                recorder.stopObserving()

                // A fresh window's content is not listening yet; the host root
                // consumes the pending target from its onAppear instead.
                #expect(recorder.receivedTargets.isEmpty)
                #expect(presenter.consumePendingNavigationTarget() == .browserImport)
                #expect(presenter.consumePendingNavigationTarget() == nil)
            }
        }

        // MARK: - Peer-window behavior

        @Test func doesNotAttachSettingsAsChildOfPreferredMainWindow() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makeFactoryWindow() })

                #expect(presenter.show() == .presented)

                let window = visibleSettingsWindow()
                #expect(window?.parent == nil)
                #expect(window?.level == .normal)
            }
        }

        @Test func adoptCmuxPeerWindowLevelBringsFloatingWindowToNormal() {
            withCleanSettingsWindows {
                let window = makeFactoryWindow()
                window.identifier = NSUserInterfaceItemIdentifier("cmux.peer.\(UUID().uuidString)")
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

        // MARK: - Pure usability policy

        @Test func unusableReasonForMissingContent() {
            let reason = SettingsWindowPresenter.unusableWindowReason(
                hasContent: false,
                frame: NSRect(x: 0, y: 0, width: 980, height: 680),
                minimumSize: SettingsWindowPresenter.minimumSize
            )
            #expect(reason != nil)
        }

        @Test func unusableReasonForDegenerateFrame() {
            let reason = SettingsWindowPresenter.unusableWindowReason(
                hasContent: true,
                frame: NSRect(x: 0, y: 0, width: 40, height: 20),
                minimumSize: SettingsWindowPresenter.minimumSize
            )
            #expect(reason != nil)
        }

        @Test func usableWindowHasNoUnusableReason() {
            let reason = SettingsWindowPresenter.unusableWindowReason(
                hasContent: true,
                frame: NSRect(x: 0, y: 0, width: 980, height: 680),
                minimumSize: SettingsWindowPresenter.minimumSize
            )
            #expect(reason == nil)
        }

        // MARK: - Multi-monitor recovery (issue #5770)

        // Screen fixtures: full frame includes the menu bar strip (top 25pt) that
        // visibleFrame excludes, mirroring real NSScreen geometry.
        private static let primaryScreen: (frame: NSRect, visibleFrame: NSRect) = (
            frame: NSRect(x: 0, y: 0, width: 1800, height: 1025),
            visibleFrame: NSRect(x: 0, y: 0, width: 1800, height: 1000)
        )
        private static let secondaryScreen: (frame: NSRect, visibleFrame: NSRect) = (
            frame: NSRect(x: 1800, y: 0, width: 1600, height: 925),
            visibleFrame: NSRect(x: 1800, y: 0, width: 1600, height: 900)
        )

        // A frame saved on a now-disconnected display sits off every active screen.
        // Selection must recover onto the screen under the cursor instead of leaving
        // Settings offscreen (the "nothing shows up" multi-monitor symptom).
        @Test func targetVisibleFrameRecoversOffscreenFrameOntoCursorScreen() {
            // Saved on a third display to the far left that is no longer connected.
            let orphanFrame = NSRect(x: -2400, y: 400, width: 980, height: 680)

            let target = SettingsWindowPresenter.targetVisibleFrame(
                windowFrame: orphanFrame,
                screens: [Self.primaryScreen, Self.secondaryScreen],
                mouseLocation: NSPoint(x: 2000, y: 450), // cursor is on the secondary screen
                fallbackVisibleFrame: Self.primaryScreen.visibleFrame
            )

            #expect(target == Self.secondaryScreen.visibleFrame)
        }

        // Opening Settings from the menu bar leaves the cursor in the strip that
        // visibleFrame excludes. Cursor recovery must hit-test the full screen
        // frame so that display is still selected, not the main-screen fallback.
        @Test func targetVisibleFrameRecoversCursorInMenuBarStripOntoThatScreen() {
            let orphanFrame = NSRect(x: -2400, y: 400, width: 980, height: 680)
            // Inside the secondary screen's full frame, above its visibleFrame.
            let menuBarCursor = NSPoint(x: 2600, y: 912)
            #expect(!Self.secondaryScreen.visibleFrame.contains(menuBarCursor))
            #expect(Self.secondaryScreen.frame.contains(menuBarCursor))

            let target = SettingsWindowPresenter.targetVisibleFrame(
                windowFrame: orphanFrame,
                screens: [Self.primaryScreen, Self.secondaryScreen],
                mouseLocation: menuBarCursor,
                fallbackVisibleFrame: Self.primaryScreen.visibleFrame
            )

            #expect(target == Self.secondaryScreen.visibleFrame)
        }

        // When the cursor is also off every active screen, fall back to main/first.
        @Test func targetVisibleFrameFallsBackWhenOffscreenAndCursorElsewhere() {
            let orphanFrame = NSRect(x: -2400, y: 400, width: 980, height: 680)

            let target = SettingsWindowPresenter.targetVisibleFrame(
                windowFrame: orphanFrame,
                screens: [Self.primaryScreen],
                mouseLocation: NSPoint(x: -3000, y: 9000), // cursor off all screens too
                fallbackVisibleFrame: Self.primaryScreen.visibleFrame
            )

            #expect(target == Self.primaryScreen.visibleFrame)
        }

        // A window mostly on a screen stays on that screen even if another exists.
        @Test func targetVisibleFramePrefersScreenWithMostOverlap() {
            let mostlyOnSecondary = NSRect(x: 1900, y: 100, width: 980, height: 680)

            let target = SettingsWindowPresenter.targetVisibleFrame(
                windowFrame: mostlyOnSecondary,
                screens: [Self.primaryScreen, Self.secondaryScreen],
                mouseLocation: NSPoint(x: 10, y: 10), // cursor on primary, but window is on secondary
                fallbackVisibleFrame: Self.primaryScreen.visibleFrame
            )

            #expect(target == Self.secondaryScreen.visibleFrame)
        }

        @Test func clampedFrameMovesOffscreenOriginInsideTargetScreen() {
            let visible = NSRect(x: 0, y: 0, width: 1800, height: 1000)
            let inset: CGFloat = 18
            // Origin far to the left/below the target screen.
            let offscreen = NSRect(x: -5000, y: -5000, width: 980, height: 680)

            let clamped = SettingsWindowPresenter.clampedFrame(
                offscreen,
                minimumSize: SettingsWindowPresenter.minimumSize,
                into: visible,
                inset: inset
            )

            #expect(clamped.size == offscreen.size)
            #expect(clamped.minX >= visible.minX + inset)
            #expect(clamped.minY >= visible.minY + inset)
            #expect(clamped.maxX <= visible.maxX - inset)
            #expect(clamped.maxY <= visible.maxY - inset)
        }

        @Test func clampedFrameShrinksOversizedFrameToVisibleArea() {
            let visible = NSRect(x: 100, y: 100, width: 1200, height: 800)
            let inset: CGFloat = 18
            let oversized = NSRect(x: 0, y: 0, width: 4000, height: 4000)

            let clamped = SettingsWindowPresenter.clampedFrame(
                oversized,
                minimumSize: SettingsWindowPresenter.minimumSize,
                into: visible,
                inset: inset
            )

            #expect(clamped.width <= visible.width - 2 * inset)
            #expect(clamped.height <= visible.height - 2 * inset)
            #expect(clamped.width >= SettingsWindowPresenter.minimumSize.width)
            #expect(clamped.height >= SettingsWindowPresenter.minimumSize.height)
        }

        // MARK: - Helpers

        private func visibleSettingsWindow() -> NSWindow? {
            visibleSettingsWindows().first
        }

        private func visibleSettingsWindows() -> [NSWindow] {
            NSApp.windows.filter {
                $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier && $0.isVisible
            }
        }

        private func waitUntil(
            timeout: Duration = .seconds(2),
            _ predicate: () -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if predicate() {
                    return true
                }
                await Task.yield()
            }
            return predicate()
        }

        private func withCleanSettingsWindows(_ body: () throws -> Void) rethrows {
            closeSettingsWindows()
            defer { closeSettingsWindows() }
            try body()
        }

        private func closeSettingsWindows() {
            for window in NSApp.windows
            where window.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier {
                window.orderOut(nil)
                window.identifier = nil
                window.close()
            }
            // Keep the shared frame-autosave slot from coupling tests together.
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame cmux.settings")
        }
    }
}

@MainActor
private func makeFactoryWindow(
    contentRect: NSRect = NSRect(x: 0, y: 0, width: 980, height: 680)
) -> TestSettingsWindow {
    let window = TestSettingsWindow(
        contentRect: contentRect,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = NSViewController()
    return window
}

@MainActor
private final class TestSettingsWindow: SettingsHostWindow {
    var factoryToken = 0
    var refusesToBecomeVisible = false
    var makeKeyAndOrderFrontCallCount = 0

    override var isVisible: Bool {
        refusesToBecomeVisible ? false : super.isVisible
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKeyAndOrderFrontCallCount += 1
        guard !refusesToBecomeVisible else { return }
        super.makeKeyAndOrderFront(sender)
    }

    override func orderFrontRegardless() {
        guard !refusesToBecomeVisible else { return }
        super.orderFrontRegardless()
    }
}

/// Records `SettingsNavigationRequest` posts on the main actor.
@MainActor
private final class SettingsNavigationRecorder: NSObject {
    private(set) var receivedTargets: [SettingsNavigationTarget] = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceive(_:)),
            name: SettingsNavigationRequest.notificationName,
            object: nil
        )
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func didReceive(_ notification: Notification) {
        if let target = SettingsNavigationRequest.target(from: notification) {
            receivedTargets.append(target)
        }
    }
}

/// Invokes `reopen` from inside the observed window's `willClose` notification.
@MainActor
private final class ReopenSettingsOnWillClose: NSObject {
    private let reopen: () -> Void

    init(window: NSWindow, reopen: @escaping () -> Void) {
        self.reopen = reopen
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        reopen()
    }
}

@MainActor
private final class SettingsSidebarToggleRecorder: NSObject {
    private(set) var receivedCount = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceiveToggle(_:)),
            name: SettingsWindowRoot.sidebarToggleRequestName,
            object: nil
        )
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func didReceiveToggle(_ notification: Notification) {
        receivedCount += 1
    }
}

@MainActor
private final class WeakSettingsWindowBox {
    weak var window: NSWindow?

    init(_ window: NSWindow) {
        self.window = window
    }
}
#endif
