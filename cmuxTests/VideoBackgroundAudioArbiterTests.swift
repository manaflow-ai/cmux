import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Video background audio arbiter", .serialized)
@MainActor
struct VideoBackgroundAudioArbiterTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeDefaults(muted: Bool) throws -> UserDefaults {
        let suiteName = "cmux.tests.videoBackgroundAudio.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: VideoBackgroundSettings.enabledKey)
        defaults.set("/tmp/cmux-video-background-audio-test.mp4", forKey: VideoBackgroundSettings.sourceKey)
        defaults.set(muted, forKey: VideoBackgroundSettings.mutedKey)
        return defaults
    }

    @Test
    func audioFollowsTheMostRecentlyKeyWindow() {
        let arbiter = VideoBackgroundAudioArbiter()
        let first = makeWindow()
        let second = makeWindow()

        arbiter.windowDidBecomeKey(first)
        #expect(arbiter.mayPlayAudio(in: first))
        #expect(!arbiter.mayPlayAudio(in: second))

        arbiter.windowDidBecomeKey(second)
        #expect(!arbiter.mayPlayAudio(in: first))
        #expect(arbiter.mayPlayAudio(in: second))

        // Closing a non-owner changes nothing; closing the owner hands off.
        arbiter.windowWillClose(first, fallback: nil)
        #expect(arbiter.mayPlayAudio(in: second))
        arbiter.windowWillClose(second, fallback: first)
        #expect(arbiter.mayPlayAudio(in: first))
        arbiter.windowWillClose(first, fallback: first)
        #expect(arbiter.ownerWindow == nil)
    }

    @Test
    func controllersStaySilentUnlessTheyOwnAudioAndTheSettingOptsIn() throws {
        let arbiter = VideoBackgroundAudioArbiter()
        let audible = try makeDefaults(muted: false)
        let first = makeWindow()
        let second = makeWindow()
        let runtime = VideoBackgroundRuntime(audioArbiter: arbiter)

        let firstController = WindowVideoBackgroundController.ensure(
            on: first,
            audioArbiter: runtime.audioArbiter,
            playbackCoordinator: runtime.playbackCoordinator,
            defaults: audible
        )
        // The first registered window owns audio without waiting for a key event.
        #expect(firstController.effectiveMuted == false)

        let secondController = WindowVideoBackgroundController.ensure(
            on: second,
            audioArbiter: runtime.audioArbiter,
            playbackCoordinator: runtime.playbackCoordinator,
            defaults: audible
        )
        #expect(secondController.effectiveMuted == true)

        arbiter.windowDidBecomeKey(second)
        #expect(firstController.effectiveMuted == true)
        #expect(secondController.effectiveMuted == false)

        // The setting always wins over ownership.
        let silent = try makeDefaults(muted: true)
        let third = makeWindow()
        let thirdController = WindowVideoBackgroundController.ensure(
            on: third,
            audioArbiter: runtime.audioArbiter,
            playbackCoordinator: runtime.playbackCoordinator,
            defaults: silent
        )
        arbiter.windowDidBecomeKey(third)
        #expect(thirdController.effectiveMuted == true)
    }
}
