import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
extension SettingsWindowSharedStateSuites {
    /// Navigation-delivery ordering and sidebar-command routing for the
    /// AppKit-hosted Settings window (issue #7777 follow-ups): a queued
    /// fresh-window navigation must deliver exactly once and never override a
    /// newer targeted open, and the shared Toggle Left Sidebar command must reach
    /// the Settings split view when the Settings window is key.
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowNavigationRoutingTests {
        @Test func queuedFreshWindowNavigationDelivers() async {
            await withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makePlainFactoryWindow() })
                let recorder = SettingsNavigationTargetRecorder()

                #expect(presenter.show(navigationTarget: .browserImport) == .presented)
                presenter.deliverPendingNavigationAfterContentAppears()
                await drainMainQueue()
                recorder.stopObserving()

                #expect(recorder.receivedTargets == [.browserImport])
            }
        }

        @Test func staleQueuedNavigationIsSupersededByNewerTargetedShow() async {
            await withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makePlainFactoryWindow() })
                let recorder = SettingsNavigationTargetRecorder()

                #expect(presenter.show(navigationTarget: .browserImport) == .presented)
                // Content appears and queues the browserImport post, but a newer
                // targeted show reuses the window and delivers synchronously
                // before the queued task runs; the stale post must stay silent.
                presenter.deliverPendingNavigationAfterContentAppears()
                #expect(presenter.show(navigationTarget: .keyboardShortcuts) == .presented)
                await drainMainQueue()
                recorder.stopObserving()

                #expect(recorder.receivedTargets == [.keyboardShortcuts])
            }
        }

        @Test func targetedReuseBeforeContentReadyKeepsNavigationPending() async {
            await withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makePlainFactoryWindow() })
                let recorder = SettingsNavigationTargetRecorder()

                // Two targeted opens land before the content ever signals
                // readiness (e.g. rapid CLI opens while the window is still
                // mounting). Nothing may be posted into the void; the latest
                // target must survive until the content appears.
                #expect(presenter.show(navigationTarget: .browserImport) == .presented)
                #expect(presenter.show(navigationTarget: .keyboardShortcuts) == .presented)
                #expect(recorder.receivedTargets.isEmpty)

                presenter.deliverPendingNavigationAfterContentAppears()
                await drainMainQueue()
                recorder.stopObserving()

                #expect(recorder.receivedTargets == [.keyboardShortcuts])
            }
        }

        @Test func untargetedShowDoesNotDropPendingNavigationTarget() async {
            await withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makePlainFactoryWindow() })
                let recorder = SettingsNavigationTargetRecorder()

                #expect(presenter.show(navigationTarget: .browserImport) == .presented)
                // An untargeted open (e.g. a menu click) lands before the content
                // appears; it must not erase the still-undelivered target.
                #expect(presenter.show() == .presented)

                presenter.deliverPendingNavigationAfterContentAppears()
                await drainMainQueue()
                recorder.stopObserving()

                #expect(recorder.receivedTargets == [.browserImport])
            }
        }

        @Test func failedTargetedShowDoesNotLeakItsTargetIntoALaterOpen() async {
            await withCleanSettingsWindows {
                var refuseVisibility = true
                let presenter = SettingsWindowPresenter(windowFactory: { _ in
                    let window = makePlainFactoryWindow()
                    window.refusesToBecomeVisible = refuseVisibility
                    return window
                })
                let recorder = SettingsNavigationTargetRecorder()

                // A targeted open fails outright (both attempts refuse to
                // present)…
                guard case .failed = presenter.show(navigationTarget: .browserImport) else {
                    Issue.record("expected the targeted show to fail")
                    recorder.stopObserving()
                    return
                }

                // …then presentation recovers and the user opens Settings with
                // no target. The dead request's pane must not resurface.
                refuseVisibility = false
                #expect(presenter.show() == .presented)
                presenter.deliverPendingNavigationAfterContentAppears()
                await drainMainQueue()
                recorder.stopObserving()

                #expect(recorder.receivedTargets.isEmpty)
            }
        }

        @Test func sidebarToggleRoutesToKeySettingsWindow() async {
            await withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter(windowFactory: { _ in makePlainFactoryWindow() })
                #expect(presenter.show() == .presented)
                let window = visibleSettingsWindow()
                #expect(window != nil)
                let recorder = SettingsSidebarToggleRecorder()

                let handled = SettingsWindowPresenter.handleSidebarToggleIfSettingsWindowIsKey(
                    keyWindow: window
                )
                recorder.stopObserving()

                #expect(handled)
                #expect(recorder.receivedCount == 1)
            }
        }

        @Test func sidebarToggleIgnoresNonSettingsKeyWindow() async {
            await withCleanSettingsWindows {
                let otherWindow = makePlainFactoryWindow()
                otherWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
                defer { otherWindow.close() }
                let recorder = SettingsSidebarToggleRecorder()

                let handledOther = SettingsWindowPresenter.handleSidebarToggleIfSettingsWindowIsKey(
                    keyWindow: otherWindow
                )
                let handledNil = SettingsWindowPresenter.handleSidebarToggleIfSettingsWindowIsKey(
                    keyWindow: nil
                )
                recorder.stopObserving()

                #expect(!handledOther)
                #expect(!handledNil)
                #expect(recorder.receivedCount == 0)
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

        /// Lets already-enqueued main-actor tasks (the deferred navigation post)
        /// run before assertions.
        private func drainMainQueue() async {
            for _ in 0..<20 {
                await Task.yield()
            }
        }
    }
}

// Shared with `SettingsWindowPresentationContractTests` (same target).
@MainActor
func makePlainFactoryWindow() -> SettingsTestHostWindow {
    let window = SettingsTestHostWindow(
        contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = NSViewController()
    return window
}

@MainActor
final class SettingsTestHostWindow: SettingsHostWindow {
    var refusesToBecomeVisible = false
    /// Simulates a window minimized to the Dock: `isMiniaturized` reports
    /// true and the window is not visible. `deminiaturize` clears the flag
    /// but — like real AppKit — visibility arrives only after the
    /// unminiaturize animation, so `isVisible` stays false for the rest of
    /// the current run-loop turn.
    var simulatesDockMiniaturization = false
    /// Models a wedged transition where `deminiaturize` followed by
    /// `orderFrontRegardless` NEVER commits visibility (the probed macOS 26
    /// behavior is a same-turn commit).
    var stallsDeminiaturizeCommit = false
    /// Models an OS where the commit lands on a later run-loop turn: after
    /// this delay, visibility appears (delivered while the presenter pumps
    /// the run loop in its bounded wait).
    var asyncDeminiaturizeCommitDelay: TimeInterval?
    private(set) var deminiaturizeCallCount = 0
    private(set) var makeKeyAndOrderFrontCallCount = 0
    private var isAwaitingDeminiaturizeAnimation = false

    override var isMiniaturized: Bool { simulatesDockMiniaturization }

    override var isVisible: Bool {
        if simulatesDockMiniaturization || isAwaitingDeminiaturizeAnimation || refusesToBecomeVisible {
            return false
        }
        return super.isVisible
    }

    override func deminiaturize(_ sender: Any?) {
        deminiaturizeCallCount += 1
        if simulatesDockMiniaturization {
            // Real AppKit: deminiaturize alone does not make the window
            // visible on the same run-loop turn.
            simulatesDockMiniaturization = false
            isAwaitingDeminiaturizeAnimation = true
            return
        }
        super.deminiaturize(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        makeKeyAndOrderFrontCallCount += 1
        guard !refusesToBecomeVisible else { return }
        super.makeKeyAndOrderFront(sender)
    }

    override func orderFrontRegardless() {
        guard !refusesToBecomeVisible else { return }
        if isAwaitingDeminiaturizeAnimation {
            if let delay = asyncDeminiaturizeCommitDelay {
                // Timer (a run-loop source), never DispatchQueue.main.asyncAfter:
                // the presenter's bounded wait pumps the run loop from inside
                // the current main-queue job, and a nested pump cannot drain
                // the serial main dispatch queue — only run-loop sources fire,
                // which is also how AppKit delivers the real commit.
                Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isAwaitingDeminiaturizeAnimation = false
                    }
                }
            } else if !stallsDeminiaturizeCommit {
                // Real AppKit (probed on macOS 26): orderFrontRegardless
                // right after deminiaturize commits visibility on the same
                // turn.
                isAwaitingDeminiaturizeAnimation = false
            }
        }
        super.orderFrontRegardless()
    }
}

/// Records `SettingsNavigationRequest` posts on the main actor.
@MainActor
private final class SettingsNavigationTargetRecorder: NSObject {
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

/// Counts settings sidebar-toggle request posts on the main actor. Uses the
/// raw notification name (the stable contract with CmuxSettingsUI's
/// `SettingsWindowRoot.sidebarToggleRequestName`) so the test target does not
/// depend on package-symbol visibility, which differs across toolchains.
@MainActor
final class SettingsSidebarToggleRecorder: NSObject {
    private(set) var receivedCount = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceive(_:)),
            name: Notification.Name("cmux.settings.toggleSidebar"),
            object: nil
        )
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func didReceive(_ notification: Notification) {
        receivedCount += 1
    }
}
#endif
