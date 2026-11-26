import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
extension SettingsWindowSharedStateSuites {
    /// End-to-end regression coverage for the "Settings won't open" family
    /// (https://github.com/manaflow-ai/cmux/issues/7777, #7775, #5770, #4053):
    /// every `show()` must end with a *visible* Settings window, synchronously,
    /// from any prior lifecycle state — fresh process, after close, after
    /// open/close churn, while a previous window is mid-close, and after the
    /// window's frame was stranded off every active screen.
    ///
    /// These tests intentionally drive the real presenter entry point with no
    /// injected opener: a request that is merely "accepted" (the pre-#7777
    /// behavior of handing the request to SwiftUI's `openWindow(id:)` and hoping
    /// the scene materializes a window) fails them.
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowOpenRegressionTests {
        @Test func showAlwaysProducesAVisibleSettingsWindow() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter()

                presenter.show()

                #expect(visibleSettingsWindow() != nil)
            }
        }

        @Test func showAfterCloseProducesAFreshVisibleSettingsWindow() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter()

                presenter.show()
                let firstWindow = visibleSettingsWindow()
                #expect(firstWindow != nil)
                firstWindow?.close()

                presenter.show()
                let secondWindow = visibleSettingsWindow()

                #expect(secondWindow != nil)
                // The reopened window must be a fresh, fully-populated window —
                // never the half-closed previous one (the #4964 blank-content and
                // #5321 lingering-window classes).
                #expect(secondWindow !== firstWindow)
            }
        }

        @Test func openCloseChurnNeverWedgesTheOpenPath() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter()

                for _ in 0..<3 {
                    presenter.show()
                    visibleSettingsWindow()?.close()
                }
                presenter.show()

                #expect(visibleSettingsWindow() != nil)
            }
        }

        @Test func showWhileSettingsWindowIsMidCloseStillProducesAVisibleWindow() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter()

                presenter.show()
                let firstWindow = visibleSettingsWindow()
                #expect(firstWindow != nil)
                guard let firstWindow else { return }

                // Re-request Settings from inside the willClose notification —
                // the previous window is torn down but still alive. The open
                // request must not be absorbed by the dying window.
                let reopener = ReopenSettingsOnWillClose(window: firstWindow) {
                    presenter.show()
                }
                firstWindow.close()
                reopener.stopObserving()

                #expect(visibleSettingsWindow() != nil)
            }
        }

        @Test func showRecoversASettingsWindowParkedOffAllScreens() {
            withCleanSettingsWindows {
                let presenter = SettingsWindowPresenter()

                presenter.show()
                let window = visibleSettingsWindow()
                #expect(window != nil)
                guard let window else { return }
                // Strand the window where no active screen can show it (the
                // saved-frame-on-a-disconnected-display shape from #5770).
                window.setFrame(
                    NSRect(x: -99_999, y: -99_999, width: 980, height: 680),
                    display: false
                )

                presenter.show()

                let recoveredFrame = visibleSettingsWindow()?.frame
                #expect(recoveredFrame != nil)
                if let recoveredFrame {
                    let intersectsAnyScreen = NSScreen.screens.contains {
                        $0.visibleFrame.intersects(recoveredFrame)
                    }
                    #expect(intersectsAnyScreen)
                }
            }
        }

        // MARK: - Helpers

        private func visibleSettingsWindow() -> NSWindow? {
            NSApp.windows.first {
                $0.identifier?.rawValue == "cmux.settings" && $0.isVisible
            }
        }

        private func withCleanSettingsWindows(_ body: () -> Void) {
            closeSettingsWindows()
            defer { closeSettingsWindows() }
            body()
        }

        private func closeSettingsWindows() {
            for window in NSApp.windows where window.identifier?.rawValue == "cmux.settings" {
                window.orderOut(nil)
                window.identifier = nil
                window.close()
            }
        }
    }
}

/// Invokes `reopen` from inside the observed window's `willClose`
/// notification, on the main actor (window notifications post on the posting
/// thread, and `NSWindow.close()` runs on the main thread in these tests).
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
