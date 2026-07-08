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
        await withCleanSettingsWindows {
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
        await withCleanSettingsWindows {
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
        await withCleanSettingsWindows {
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
        await withCleanSettingsWindows {
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
        await withCleanSettingsWindows {
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
            #expect(settingsWindow.identifier == nil)
        }
    }

    @Test func showReusesTrackedOrderedOutSettingsWindow() async throws {
        await withCleanSettingsWindows {
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
        await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            var openCallCount = 0

            presenter.show(openWindowOverride: { openCallCount += 1 })
            presenter.show(openWindowOverride: { openCallCount += 1 })

            #expect(openCallCount == 1)
        }
    }

    @Test func refocusIfVisibleDoesNotReopenClosedSettingsWindow() async throws {
        await withCleanSettingsWindows {
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
        await withCleanSettingsWindows {
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
        await withCleanSettingsWindows {
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
        await withCleanSettingsWindows {
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
        await withCleanSettingsWindows {
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

    // MARK: - Silent no-op recovery (issue #5770 / #4053)

    // The "click Settings and nothing happens" symptom: the open request is
    // dispatched but no window ever materializes. The presenter must notice
    // the silently-dropped request and re-request the window, bounded at
    // exactly one retry by maxOpenAttempts.
    @Test func showReRequestsWindowWhenOpenRequestSilentlyProducesNoWindow() async throws {
        await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            var openRequests = 0
            presenter.configure(openWindow: { openRequests += 1 })

            presenter.show()
            #expect(openRequests == 1)

            let outcome = presenter.resolveOpenVerification(
                attempt: 1,
                opener: { openRequests += 1 }
            )

            #expect(outcome == .retry)
            #expect(openRequests == 2)
        }
    }

    // show() before configure(openWindow:) defers the open request; the
    // deferred request must get the same lost-request verification as a
    // direct one instead of being fired blind.
    @Test func deferredOpenRequestAlsoVerifiesAndRetries() async throws {
        await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            var openRequests = 0

            presenter.show()
            #expect(openRequests == 0)

            presenter.configure(openWindow: { openRequests += 1 })
            #expect(openRequests == 1)

            let outcome = presenter.resolveOpenVerification(
                attempt: 1,
                opener: { openRequests += 1 }
            )

            #expect(outcome == .retry)
            #expect(openRequests == 2)
        }
    }

    // An override opener (e.g. BrowserPanelView.openBrowserImportSettings still
    // calls SwiftUI openWindow(id:)) hits the same mid-teardown no-op, so it
    // must get the same lost-request verification and single retry.
    @Test func overrideOpenRequestAlsoVerifiesAndRetries() async throws {
        await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            var openRequests = 0

            presenter.show(openWindowOverride: { openRequests += 1 })
            #expect(openRequests == 1)

            let outcome = presenter.resolveOpenVerification(
                attempt: 1,
                opener: { openRequests += 1 }
            )

            #expect(outcome == .retry)
            #expect(openRequests == 2)
        }
    }

    @Test func retryKeepsOpeningRequestsCoalescedUntilWindowMaterializes() async throws {
        await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            var openRequests = 0

            presenter.show(openWindowOverride: { openRequests += 1 })
            #expect(openRequests == 1)

            let outcome = presenter.resolveOpenVerification(
                attempt: 1,
                opener: { openRequests += 1 }
            )
            #expect(outcome == .retry)
            #expect(openRequests == 2)

            presenter.show(openWindowOverride: { openRequests += 1 })
            #expect(openRequests == 2)
        }
    }

    @Test func scheduledVerificationCanAdvanceWithoutRealWaiting() async throws {
        await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter(openVerificationDelay: .zero)
            var openRequests = 0

            presenter.show(openWindowOverride: { openRequests += 1 })
            #expect(openRequests == 1)

            for _ in 0..<20 {
                if openRequests == 2 { break }
                await Task.yield()
            }

            #expect(openRequests == 2)
        }
    }

    @Test func giveUpClearsOpeningFlagSoNextShowCanRequestAgain() async throws {
        await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            var openRequests = 0

            presenter.show(openWindowOverride: { openRequests += 1 })
            #expect(openRequests == 1)

            let outcome = presenter.resolveOpenVerification(
                attempt: SettingsWindowPresenter.maxOpenAttempts,
                opener: { openRequests += 1 }
            )
            #expect(outcome == .giveUp)

            presenter.show(openWindowOverride: { openRequests += 1 })
            #expect(openRequests == 2)
        }
    }

    @Test func materializedVerificationUsesIdentifierScannedWindowAndClearsOpeningFlag() async throws {
        await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter()
            var openRequests = 0

            presenter.show(openWindowOverride: { openRequests += 1 })
            #expect(openRequests == 1)

            let settingsWindow = makeWindow(identifier: SettingsWindowPresenter.windowIdentifier)
            defer {
                settingsWindow.orderOut(nil)
                settingsWindow.close()
            }

            let outcome = presenter.resolveOpenVerification(
                attempt: 1,
                opener: { openRequests += 1 }
            )
            #expect(outcome == .materialized)

            presenter.show(openWindowOverride: { openRequests += 1 })

            #expect(openRequests == 1)
            #expect(settingsWindow.makeKeyAndOrderFrontCallCount == 1)
        }
    }

    @Test func openOutcomeRetriesWhenWindowDoesNotMaterializeOnFirstAttempt() {
        #expect(SettingsWindowPresenter.openOutcome(windowExists: false, attempt: 1) == .retry)
    }

    @Test func openOutcomeGivesUpAfterMaxAttempts() {
        #expect(
            SettingsWindowPresenter.openOutcome(
                windowExists: false,
                attempt: SettingsWindowPresenter.maxOpenAttempts
            ) == .giveUp
        )
    }

    @Test func openOutcomeIsMaterializedWhenWindowExists() {
        #expect(SettingsWindowPresenter.openOutcome(windowExists: true, attempt: 1) == .materialized)
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
