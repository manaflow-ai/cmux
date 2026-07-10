import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
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
            let presenter = SettingsWindowPresenter(windowFactory: { makePlainFactoryWindow() })
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
            let presenter = SettingsWindowPresenter(windowFactory: { makePlainFactoryWindow() })
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
            let presenter = SettingsWindowPresenter(windowFactory: { makePlainFactoryWindow() })
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

    @Test func sidebarToggleRoutesToKeySettingsWindow() async {
        await withCleanSettingsWindows {
            let presenter = SettingsWindowPresenter(windowFactory: { makePlainFactoryWindow() })
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

@MainActor
private func makePlainFactoryWindow() -> SettingsHostWindow {
    let window = SettingsHostWindow(
        contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = NSViewController()
    return window
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

/// Counts `SettingsWindowRoot.sidebarToggleRequestName` posts on the main actor.
@MainActor
private final class SettingsSidebarToggleRecorder: NSObject {
    private(set) var receivedCount = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceive(_:)),
            name: SettingsWindowRoot.sidebarToggleRequestName,
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
