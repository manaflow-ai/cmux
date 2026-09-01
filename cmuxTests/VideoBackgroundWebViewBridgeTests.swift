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
        var endedCount = 0
        let bridge = VideoBackgroundWebViewBridge(onPlayerError: { failures.append($0) })
        bridge.onPlayerReady = { readyCount += 1 }
        bridge.onPlayerEnded = { endedCount += 1 }

        bridge.handleScriptEvent(["event": "ready"])
        #expect(readyCount == 1)
        #expect(failures.isEmpty)

        bridge.handleScriptEvent(["event": "skipped", "code": 101])
        #expect(readyCount == 1)
        bridge.handleScriptEvent(["event": "ended"])
        #expect(endedCount == 1)
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
        var model = VideoBackgroundPlaybackCommandModel(muted: true, volume: 1)
        var scripts: [String] = []

        // A window created while occluded pauses before the page exists.
        if let command = model.setPaused(true) { scripts.append(command) }
        if let command = model.setPaused(true) { scripts.append(command) }
        #expect(scripts == [VideoBackgroundEmbedPage.pauseScript])

        // The early script was dropped by WebKit; readiness replays the full
        // desired state through the pure model.
        scripts.append(contentsOf: model.replayCommands())
        #expect(scripts == [
            VideoBackgroundEmbedPage.pauseScript,
            VideoBackgroundEmbedPage.pauseScript,
            VideoBackgroundEmbedPage.mutedScript(true),
            VideoBackgroundEmbedPage.volumeScript(1),
        ])

        if let command = model.setPaused(false) { scripts.append(command) }
        #expect(scripts.last == VideoBackgroundEmbedPage.resumeScript)
        if let command = model.setMuted(false) { scripts.append(command) }
        if let command = model.setMuted(false) { scripts.append(command) }
        #expect(scripts.last == VideoBackgroundEmbedPage.mutedScript(false))
        scripts.append(contentsOf: model.replayCommands())
        #expect(scripts.suffix(3) == [
            VideoBackgroundEmbedPage.resumeScript,
            VideoBackgroundEmbedPage.mutedScript(false),
            VideoBackgroundEmbedPage.volumeScript(1),
        ])
    }

    @Test
    func commandModelDeduplicatesAndClampsChanges() {
        var model = VideoBackgroundPlaybackCommandModel(muted: true, initialPosition: -1, volume: 2)
        #expect(model.position == 0)
        #expect(model.volume == 1)
        #expect(model.setPaused(false) == nil)
        #expect(model.setMuted(true) == nil)
        #expect(model.setPosition(0.01) == nil)
        #expect(model.setVolume(1.001) == nil)
        #expect(model.setVolume(0.5) == VideoBackgroundEmbedPage.volumeScript(0.5))
    }
}
