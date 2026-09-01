import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Video background web bridge")
@MainActor
struct VideoBackgroundWebViewBridgeTests {
    @Test
    func routesPageEventsToTheirCallbacks() {
        var failures: [String] = []
        var readyCount = 0
        let bridge = VideoBackgroundWebViewBridge(onPlayerError: { failures.append($0) })
        bridge.onPlayerReady = { readyCount += 1 }

        bridge.handleScriptEvent(["event": "ready"])
        #expect(readyCount == 1)
        #expect(failures.isEmpty)

        bridge.handleScriptEvent(["event": "skipped", "code": 101])
        #expect(readyCount == 1)
        #expect(failures.isEmpty)

        bridge.handleScriptEvent(["event": "error", "code": 150])
        #expect(failures == ["player-error: 150"])

        bridge.handleScriptEvent("not a dictionary")
        bridge.handleScriptEvent(["code": 1])
        #expect(readyCount == 1)
        #expect(failures.count == 1)
    }

    @Test
    func replaysDesiredPauseStateWhenThePlayerBecomesReady() {
        let view = VideoBackgroundWebPlayerView(source: .youTubeVideo(id: "dQw4w9WgXcQ")) { _ in }
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }

        // A window created while occluded pauses before the page exists.
        view.setPaused(true)
        view.setPaused(true)
        #expect(scripts == [VideoBackgroundEmbedPage.pauseScript])

        // The early script was dropped by WebKit; readiness must re-assert it.
        view.bridge.handleScriptEvent(["event": "ready"])
        #expect(scripts == [VideoBackgroundEmbedPage.pauseScript, VideoBackgroundEmbedPage.pauseScript])

        view.setPaused(false)
        #expect(scripts.last == VideoBackgroundEmbedPage.resumeScript)
        view.bridge.handleScriptEvent(["event": "ready"])
        #expect(scripts.suffix(2) == [VideoBackgroundEmbedPage.resumeScript, VideoBackgroundEmbedPage.resumeScript])
    }
}
