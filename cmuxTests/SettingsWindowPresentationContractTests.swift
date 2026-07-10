import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
extension SettingsWindowSharedStateSuites {
    /// Presentation-contract coverage for ``SettingsWindowPresenter`` (issue
    /// #7777 follow-ups): a Dock-miniaturized window is reused and its
    /// deminiaturization awaited (unsaved edits survive), a wedged transition
    /// self-heals by replacement, a failed show never activates or keys
    /// anything, and close-triggered re-entrant shows recover boundedly.
    /// Split from `SettingsWindowNavigationRoutingTests` to stay under the
    /// Swift file-length threshold; shares its window helpers.
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowPresentationContractTests {
        @Test func closingTheWindowDuringTheDeminiaturizeWaitIsNotResurrected() async {
            await withCleanSettingsWindows {
                var builtWindows: [SettingsTestHostWindow] = []
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    let window = makePlainFactoryWindow()
                    builtWindows.append(window)
                    return window
                })
                #expect(presenter.show() == .presented)
                guard let firstWindow = builtWindows.first else {
                    Issue.record("expected the first show to build a window")
                    return
                }

                // The window is reopening from the Dock and the user closes
                // it while the presenter pumps the run loop waiting for the
                // transition to land. The show must abort — never build a
                // replacement that resurrects a window the user just closed.
                firstWindow.simulatesDockMiniaturization = true
                firstWindow.stallsDeminiaturizeCommit = true
                // Timer (a run-loop source), never DispatchQueue.main.asyncAfter:
                // the presenter's bounded wait pumps the run loop from inside
                // the current main-queue job, and a nested pump cannot drain
                // the serial main dispatch queue — only run-loop sources fire,
                // which is also how AppKit delivers the real transition.
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak firstWindow] _ in
                    MainActor.assumeIsolated {
                        firstWindow?.close()
                    }
                }

                let result = presenter.show()

                guard case .failed = result else {
                    Issue.record("expected .failed after a mid-wait close, got \(result)")
                    return
                }
                #expect(builtWindows.count == 1)
                #expect(visibleSettingsWindow() == nil)
            }
        }

        @Test func reentrantReplacementDuringDeminiaturizeWaitIsActivated() async {
            await withCleanSettingsWindows {
                var builtWindows: [SettingsTestHostWindow] = []
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    let window = makePlainFactoryWindow()
                    builtWindows.append(window)
                    return window
                })
                #expect(presenter.show() == .presented)
                guard let firstWindow = builtWindows.first else {
                    Issue.record("expected the first show to build a window")
                    return
                }

                // The stalled Dock reopen is interrupted by a close, and a
                // foreign willClose observer immediately reopens Settings
                // without activation. The outer (activating) show must adopt
                // that replacement AND still honor its activation semantics —
                // returning .presented for a window that was never keyed
                // would leave the app inactive.
                firstWindow.simulatesDockMiniaturization = true
                firstWindow.stallsDeminiaturizeCommit = true
                let reopener = ReopenOnSettingsTestWindowClose {
                    _ = presenter.show(activateApp: false)
                }
                // Timer (a run-loop source), never DispatchQueue.main.asyncAfter:
                // the presenter's bounded wait pumps the run loop from inside
                // the current main-queue job, and a nested pump cannot drain
                // the serial main dispatch queue — only run-loop sources fire,
                // which is also how AppKit delivers the real transition.
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak firstWindow] _ in
                    MainActor.assumeIsolated {
                        firstWindow?.close()
                    }
                }

                let result = presenter.show()
                reopener.stopObserving()

                #expect(result == .presented)
                #expect(builtWindows.count == 2)
                guard builtWindows.count == 2, let replacement = builtWindows.last,
                      replacement !== firstWindow else { return }
                #expect(replacement.isVisible)
                #expect(replacement.makeKeyAndOrderFrontCallCount >= 1)
            }
        }

        @Test func reentrantShowDuringDeminiaturizeWaitCoalescesOntoTheTransition() async {
            await withCleanSettingsWindows {
                var builtWindows: [SettingsTestHostWindow] = []
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    let window = makePlainFactoryWindow()
                    builtWindows.append(window)
                    return window
                })
                #expect(presenter.show() == .presented)
                guard let firstWindow = builtWindows.first else {
                    Issue.record("expected the first show to build a window")
                    return
                }

                // A second open (repeated ⌘, / concurrent socket request)
                // lands while the deminiaturization is still committing.
                // `deminiaturize` has already cleared `isMiniaturized`, so
                // without in-flight tracking the re-entrant show would see a
                // plain invisible window and demolish the live transition —
                // destroying the unsaved edits this design preserves.
                firstWindow.simulatesDockMiniaturization = true
                firstWindow.asyncDeminiaturizeCommitDelay = 0.2
                var reentrantResult: SettingsWindowShowResult?
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        reentrantResult = presenter.show()
                    }
                }

                let result = presenter.show()

                #expect(result == .presented)
                #expect(reentrantResult == .presented)
                #expect(builtWindows.count == 1)
                #expect(firstWindow.isVisible)
                #expect(firstWindow.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier)
            }
        }

        @Test func miniaturizedSettingsWindowIsReusedAndVisibleOnReturn() async {
            await withCleanSettingsWindows {
                var builtWindows: [SettingsTestHostWindow] = []
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    let window = makePlainFactoryWindow()
                    builtWindows.append(window)
                    return window
                })
                #expect(presenter.show() == .presented)
                guard let firstWindow = builtWindows.first else {
                    Issue.record("expected the first show to build a window")
                    return
                }

                // The user minimizes Settings to the Dock, then reopens it.
                firstWindow.simulatesDockMiniaturization = true

                let result = presenter.show()

                // The miniaturized window is REUSED — demolishing it would
                // destroy unsaved Settings edits — and deminiaturize followed
                // by orderFrontRegardless commits visibility on the same
                // run-loop turn (probed AppKit behavior the simulation
                // models), so the verified visible-on-return contract holds.
                #expect(result == .presented)
                #expect(builtWindows.count == 1)
                #expect(firstWindow.deminiaturizeCallCount == 1)
                #expect(firstWindow.isVisible)
                #expect(firstWindow.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier)
            }
        }

        @Test func asyncDeminiaturizeCommitIsAwaitedWithoutReplacingTheWindow() async {
            await withCleanSettingsWindows {
                var builtWindows: [SettingsTestHostWindow] = []
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    let window = makePlainFactoryWindow()
                    builtWindows.append(window)
                    return window
                })
                #expect(presenter.show() == .presented)
                guard let firstWindow = builtWindows.first else {
                    Issue.record("expected the first show to build a window")
                    return
                }

                // OS where the deminiaturize commit lands on a LATER
                // run-loop turn: the bounded wait must let AppKit finish the
                // transition — never tear down a live window (and its
                // unsaved edits) that is about to appear.
                firstWindow.simulatesDockMiniaturization = true
                firstWindow.asyncDeminiaturizeCommitDelay = 0.1

                let result = presenter.show()

                #expect(result == .presented)
                #expect(builtWindows.count == 1)
                #expect(firstWindow.isVisible)
                #expect(firstWindow.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier)
            }
        }

        @Test func stalledDeminiaturizeCommitFallsBackToAFreshVisibleWindow() async {
            await withCleanSettingsWindows {
                let previousTimeout = SettingsWindowPresenter.deminiaturizeSettleTimeout
                SettingsWindowPresenter.deminiaturizeSettleTimeout = 0.1
                defer { SettingsWindowPresenter.deminiaturizeSettleTimeout = previousTimeout }
                var builtWindows: [SettingsTestHostWindow] = []
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    let window = makePlainFactoryWindow()
                    builtWindows.append(window)
                    return window
                })
                #expect(presenter.show() == .presented)
                guard let firstWindow = builtWindows.first else {
                    Issue.record("expected the first show to build a window")
                    return
                }

                // A window whose deminiaturization never lands (wedged
                // transition): the open must still end in a visible window
                // (self-heal by replacement), never a silent no-op or a
                // pending state reported as success.
                firstWindow.simulatesDockMiniaturization = true
                firstWindow.stallsDeminiaturizeCommit = true

                let result = presenter.show()

                #expect(result == .presented)
                #expect(builtWindows.count == 2)
                #expect(firstWindow.identifier == nil)
                let visible = visibleSettingsWindow()
                #expect(visible != nil)
                #expect(visible !== firstWindow)
            }
        }

        @Test func failedShowNeverActivatesOrKeysAnInvisibleWindow() async {
            await withCleanSettingsWindows {
                var builtWindows: [SettingsTestHostWindow] = []
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    let window = makePlainFactoryWindow()
                    window.refusesToBecomeVisible = true
                    builtWindows.append(window)
                    return window
                })

                guard case .failed = presenter.show() else {
                    Issue.record("expected .failed when no window becomes visible")
                    return
                }

                // Activation and key ordering are post-verification steps: a
                // presentation that never became visible must not have keyed
                // any window (the app would otherwise activate and steal
                // focus while showing nothing).
                #expect(!builtWindows.isEmpty)
                #expect(builtWindows.allSatisfy { $0.makeKeyAndOrderFrontCallCount == 0 })
            }
        }

        // MARK: - Re-entrant teardown recovery

        @Test func reentrantReopenDuringTeardownAdoptsReplacementWindow() async {
            await withCleanSettingsWindows {
                var buildCount = 0
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    buildCount += 1
                    let window = makePlainFactoryWindow()
                    // Only the first window refuses to present, forcing a
                    // demolish whose close re-enters show() via the observer.
                    window.refusesToBecomeVisible = buildCount == 1
                    return window
                })
                let reopener = ReopenOnSettingsTestWindowClose {
                    _ = presenter.show()
                }

                let result = presenter.show()
                reopener.stopObserving()

                // The outer retry must adopt the window the re-entrant show
                // created, not build a duplicate next to it.
                #expect(result == .presented)
                #expect(buildCount == 2)
                let visibleCount = NSApp.windows.filter {
                    $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier && $0.isVisible
                }.count
                #expect(visibleCount == 1)
            }
        }

        @Test func pathologicalReopenOnCloseFailsLoudlyInsteadOfRecursing() async {
            await withCleanSettingsWindows {
                var buildCount = 0
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    buildCount += 1
                    let window = makePlainFactoryWindow()
                    window.refusesToBecomeVisible = true
                    return window
                })
                let reopener = ReopenOnSettingsTestWindowClose {
                    _ = presenter.show()
                }

                let result = presenter.show()
                reopener.stopObserving()

                // Every window refuses to present and every close re-enters
                // show(): the depth bound must convert this into a loud failure
                // with a bounded number of attempts, never a runaway recursion.
                guard case .failed = result else {
                    Issue.record("expected .failed, got \(result)")
                    return
                }
                #expect(buildCount < 20)
                let visibleCount = NSApp.windows.filter {
                    $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier && $0.isVisible
                }.count
                #expect(visibleCount == 0)
            }
        }

        // MARK: - Helpers

        private func visibleSettingsWindow() -> NSWindow? {
            NSApp.windows.first {
                $0.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier && $0.isVisible
            }
        }

        private func withCleanSettingsWindows(_ body: () async throws -> Void) async rethrows {
            closeSettingsWindows()
            defer { closeSettingsWindows() }
            try await body()
        }

        private func closeSettingsWindows() {
            for window in NSApp.windows
            where window.identifier?.rawValue == SettingsWindowPresenter.windowIdentifier {
                window.orderOut(nil)
                window.identifier = nil
                window.close()
            }
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame cmux.settings")
        }
    }
}

/// Re-enters the given closure from any `SettingsTestHostWindow`'s willClose
/// notification (the presenter's demolish closes windows synchronously).
@MainActor
private final class ReopenOnSettingsTestWindowClose: NSObject {
    private let reopen: () -> Void

    init(reopen: @escaping () -> Void) {
        self.reopen = reopen
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        guard notification.object is SettingsTestHostWindow else { return }
        reopen()
    }
}
#endif
