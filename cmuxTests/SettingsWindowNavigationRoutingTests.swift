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

        /// Lets already-enqueued main-actor tasks (the deferred navigation post)
        /// run before assertions.
        private func drainMainQueue() async {
            for _ in 0..<20 {
                await Task.yield()
            }
        }
    }
}

@MainActor
private func makePlainFactoryWindow() -> SettingsTestHostWindow {
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
private final class SettingsTestHostWindow: SettingsHostWindow {
    var refusesToBecomeVisible = false

    override var isVisible: Bool {
        refusesToBecomeVisible ? false : super.isVisible
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        guard !refusesToBecomeVisible else { return }
        super.makeKeyAndOrderFront(sender)
    }

    override func orderFrontRegardless() {
        guard !refusesToBecomeVisible else { return }
        super.orderFrontRegardless()
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
private final class SettingsSidebarToggleRecorder: NSObject {
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
