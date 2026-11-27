import AppKit
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

        @Test func closingReleasesTheWindowContent() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makeFactoryWindow() })

                #expect(presenter.show() == .presented)
                let window = visibleSettingsWindow()
                #expect(window?.contentViewController != nil)

                window?.close()

                // The content tree is released with the window so a closed
                // Settings cannot linger half-alive (#4964 / #5321 classes).
                #expect(window?.contentViewController == nil)
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
            NSApp.windows.first {
                $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier && $0.isVisible
            }
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
#endif
