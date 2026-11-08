import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The config diagnostics card is placed under the chrome cmux draws itself,
/// not under AppKit's native titlebar. Minimal mode draws no titlebar band, so
/// the two modes do not have the same amount of chrome to clear.
@MainActor
struct GhosttyConfigDiagnosticsNoticePlacementTests {
    @Test
    func standardModeClearsTheTitlebarAndTheTabBar() {
        #expect(
            GhosttyConfigDiagnosticsNoticePresenter.chromeHeight(isMinimalMode: false)
                == WindowChromeMetrics.appTitlebarHeight + WindowChromeMetrics.bonsplitTabBarHeight
        )
    }

    @Test
    func minimalModeClearsTheTabBarOnly() {
        // WorkspaceTitlebarModeLayer renders the titlebar band only when the
        // presentation mode is not minimal, so counting it here would push the
        // card a titlebar's height down over live terminal content.
        #expect(
            GhosttyConfigDiagnosticsNoticePresenter.chromeHeight(isMinimalMode: true)
                == WindowChromeMetrics.bonsplitTabBarHeight
        )
    }

    @Test
    func minimalModeSitsHigherThanStandardMode() {
        #expect(
            GhosttyConfigDiagnosticsNoticePresenter.chromeHeight(isMinimalMode: true)
                < GhosttyConfigDiagnosticsNoticePresenter.chromeHeight(isMinimalMode: false)
        )
    }
}
