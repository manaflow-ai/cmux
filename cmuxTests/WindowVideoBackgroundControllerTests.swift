import AppKit
import AVFoundation
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Local video background playback", .serialized)
@MainActor
struct VideoBackgroundLocalPlaybackTests {
    @MainActor
    private final class PlaybackEvents {
        var readyCount = 0
        var endedCount = 0
        var failures: [String] = []
    }

    @Test func loopingMediaReportsReadinessAndPlaysAtLeastThreeTimes() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-video-loop-\(UUID().uuidString).mp4")
        try silentVideo().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let events = PlaybackEvents()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let item = notification.object as? AVPlayerItem,
                      let asset = item.asset as? AVURLAsset,
                      asset.url == fileURL else { return }
                events.endedCount += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let view = VideoBackgroundLocalPlayerView(
            fileURL: fileURL,
            onReady: { events.readyCount += 1 },
            onFailure: { events.failures.append($0) }
        )
        defer { view.setPaused(true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while (events.endedCount < 3 || events.readyCount == 0), events.failures.isEmpty,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(events.failures.isEmpty)
        #expect(events.readyCount == 1)
        #expect(events.endedCount >= 3)
        #expect(view.hitTest(.zero) == nil)
    }

    @Test(arguments: [false, true])
    func missingLocalMediaReportsFailure(loops: Bool) async throws {
        let events = PlaybackEvents()
        let view = VideoBackgroundLocalPlayerView(
            fileURL: URL(fileURLWithPath: "/tmp/cmux-missing-video-\(UUID().uuidString).mp4"),
            loops: loops,
            onReady: { events.readyCount += 1 },
            onFailure: { events.failures.append($0) }
        )
        defer { view.setPaused(true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while events.failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(events.readyCount == 0)
        #expect(events.failures == ["local-file-failed"])
    }

    private func silentVideo() throws -> Data {
        try #require(Data(base64Encoded: """
            AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAN1bW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAfQAAQAAAQAA
            AAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAA
            Ap90cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAfQAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAA
            AAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAH0AAAIAAABAAAAAAIXbWRpYQAAACBtZGhk
            AAAAAAAAAAAAAAAAAAAoAAAAFABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABwm1p
            bmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAYJzdGJsAAAAvnN0c2QA
            AAAAAAAAAQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGli
            eDI2NAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAF2dkAAqs2V7ARAAAAwAEAAADAFA8SJZYAQAGaOvjyyLA/fj4AAAAABBw
            YXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAC+gAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAFAAAEAAAAABRzdHNzAAAAAAAAAAEAAAAB
            AAAAOGN0dHMAAAAAAAAABQAAAAEAAAgAAAAAAQAAFAAAAAABAAAIAAAAAAEAAAAAAAAAAQAABAAAAAAcc3RzYwAAAAAAAAABAAAA
            AQAAAAUAAAABAAAAKHN0c3oAAAAAAAAAAAAAAAUAAALKAAAADAAAAAwAAAAMAAAADAAAABRzdGNvAAAAAAAAAAEAAAOlAAAAYnVk
            dGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAAB
            AAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAAAwJtZGF0AAACrgYF//+q3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSBy
            MzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlk
            ZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDEx
            MyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0x
            IHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0
            aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAg
            Ymx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9MSBiX2JpYXM9
            MCBkaXJlY3Q9MSB3ZWlnaHRiPTEgb3Blbl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1MCBrZXlpbnRfbWluPTEwIHNjZW5lY3V0
            PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAgcmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBt
            aW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAFGWIhAAQ//7mwPmWWrhc4Ae+iwi/AAAA
            CEGaJGxDf/7gAAAACEGeQniHf7eBAAAACAGeYXRDf7qAAAAACAGeY2pDf7qB
            """, options: .ignoreUnknownCharacters))
    }
}

@Suite("Window video background controller", .serialized)
@MainActor
struct WindowVideoBackgroundControllerTests {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "cmux.tests.videoBackground.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

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

    private func hostView(in window: NSWindow) -> NSView? {
        window.contentView?.superview?.subviews.first { $0 is VideoBackgroundHostView }
    }

    @Test
    func disabledSettingInstallsNothingAndReportsInactive() throws {
        let defaults = try makeDefaults()
        defaults.set("/tmp/cmux-video-background-test.mp4", forKey: VideoBackgroundSettings.sourceKey)
        let window = makeWindow()
        defer { window.close() }
        let runtime = VideoBackgroundRuntime(
            audioArbiter: VideoBackgroundAudioArbiter(),
            playbackCoordinator: VideoBackgroundPlaybackCoordinator()
        )

        let controller = WindowVideoBackgroundController.ensure(
            on: window,
            audioArbiter: runtime.audioArbiter,
            playbackCoordinator: runtime.playbackCoordinator,
            defaults: defaults
        )

        #expect(controller.presentation.isActive == false)
        #expect(hostView(in: window) == nil)
    }

    @Test
    func installsBelowContentViewBeforePlayerReadiness() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: VideoBackgroundSettings.enabledKey)
        defaults.set("/tmp/cmux-video-background-test.mp4", forKey: VideoBackgroundSettings.sourceKey)
        let window = makeWindow()
        defer { window.close() }
        let runtime = VideoBackgroundRuntime(
            audioArbiter: VideoBackgroundAudioArbiter(),
            playbackCoordinator: VideoBackgroundPlaybackCoordinator()
        )

        let controller = WindowVideoBackgroundController.ensure(
            on: window,
            audioArbiter: runtime.audioArbiter,
            playbackCoordinator: runtime.playbackCoordinator,
            defaults: defaults
        )

        // A local player reports active only after AVFoundation confirms that
        // the file can render; this intentionally uses a missing path to
        // exercise the pre-readiness state.
        #expect(controller.presentation.isActive == false)
        let themeFrame = try #require(window.contentView?.superview)
        let hostIndex = try #require(themeFrame.subviews.firstIndex { $0 is VideoBackgroundHostView })
        let contentIndex = try #require(themeFrame.subviews.firstIndex { $0 === window.contentView })
        #expect(hostIndex < contentIndex, "video layer must composite below the content view")
        #expect(
            WindowVideoBackgroundController.ensure(
                on: window,
                audioArbiter: runtime.audioArbiter,
                playbackCoordinator: runtime.playbackCoordinator,
                defaults: defaults
            ) === controller
        )
    }

    @Test
    func playerFailureRemovesTheLayerAndReportsInactiveUntilTheSourceChanges() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: VideoBackgroundSettings.enabledKey)
        defaults.set("/tmp/cmux-video-background-broken.mp4", forKey: VideoBackgroundSettings.sourceKey)
        let window = makeWindow()
        defer { window.close() }
        let runtime = VideoBackgroundRuntime(
            audioArbiter: VideoBackgroundAudioArbiter(),
            playbackCoordinator: VideoBackgroundPlaybackCoordinator()
        )
        let controller = WindowVideoBackgroundController.ensure(
            on: window,
            audioArbiter: runtime.audioArbiter,
            playbackCoordinator: runtime.playbackCoordinator,
            defaults: defaults
        )
        #expect(controller.presentation.isActive == false)

        controller.handlePlayerFailure(reason: "test")

        #expect(controller.presentation.isActive == false)
        #expect(hostView(in: window) == nil)

        // The failed source stays latched: re-running the configuration pass
        // must not reinstall a layer that would fail again.
        controller.refresh()
        #expect(controller.presentation.isActive == false)
        #expect(hostView(in: window) == nil)

        // Editing the source clears the latch and retries.
        defaults.set("/tmp/cmux-video-background-fixed.mp4", forKey: VideoBackgroundSettings.sourceKey)
        controller.refresh()
        #expect(controller.presentation.isActive == false)
        #expect(hostView(in: window) != nil)
    }

    @Test
    func sharedPlaybackCoordinatorKeepsQueueIndexAndRejectsStaleEndEvents() {
        let coordinator = VideoBackgroundPlaybackCoordinator()
        var snapshots: [VideoBackgroundPlaybackCoordinator.Snapshot] = []
        let initial = coordinator.configure(
            sourceTexts: ["dQw4w9WgXcQ", "M7lc1UVf-VE"],
            quality: "1080p"
        )
        let registration = coordinator.register { snapshot in
            snapshots.append(snapshot)
        }

        #expect(initial.index == 0)
        #expect(initial.sources.count == 2)
        #expect(registration.snapshot.currentSource == initial.currentSource)

        coordinator.advance(after: initial.generation &- 1)
        #expect(snapshots.isEmpty)

        coordinator.advance(after: initial.generation)
        #expect(snapshots.count == 1)
        if let advanced = snapshots.last {
            #expect(advanced.index == 1)
            #expect(advanced.generation != initial.generation)
        }

        coordinator.unregister(registration.token)
        coordinator.advance(after: snapshots.last?.generation ?? 0)
        #expect(snapshots.count == 1)
    }

    @Test
    func sharedPlayheadFreezesWhenTheLastPlayerPauses() {
        var clock: CFTimeInterval = 100
        let coordinator = VideoBackgroundPlaybackCoordinator(now: { clock })
        _ = coordinator.configure(
            sourceTexts: ["dQw4w9WgXcQ"],
            quality: "1080p"
        )
        let first = coordinator.register { _ in }
        let second = coordinator.register { _ in }

        coordinator.setPlayerRunning(true, for: first.token)
        clock += 5
        #expect(abs(coordinator.synchronizedSnapshot().position - 5) < 0.001)

        // Once the only running player pauses, elapsed time must stop counting
        // even if the app remains backgrounded for a long interval.
        coordinator.setPlayerRunning(false, for: first.token)
        clock += 100
        #expect(abs(coordinator.synchronizedSnapshot().position - 5) < 0.001)

        // A second visible window resumes from the frozen position.
        coordinator.setPlayerRunning(true, for: second.token)
        clock += 2
        #expect(abs(coordinator.synchronizedSnapshot().position - 7) < 0.001)
        coordinator.setPlayerRunning(false, for: second.token)
    }

    @Test
    func failedQueueEntriesAdvanceOnceAndExhaustAfterEveryEntryFails() {
        let coordinator = VideoBackgroundPlaybackCoordinator()
        var snapshots: [VideoBackgroundPlaybackCoordinator.Snapshot] = []
        let initial = coordinator.configure(
            sourceTexts: ["dQw4w9WgXcQ", "M7lc1UVf-VE"],
            quality: "1080p"
        )
        let registration = coordinator.register { snapshot in
            snapshots.append(snapshot)
        }

        coordinator.recordFailure(after: initial.generation)
        let second = coordinator.synchronizedSnapshot()
        #expect(second.currentSource == .youTubeVideo(id: "M7lc1UVf-VE"))

        coordinator.recordFailure(after: second.generation)
        let exhausted = coordinator.synchronizedSnapshot()
        #expect(exhausted.currentSource == nil)
        #expect(exhausted.sources.count == 2)
        #expect(snapshots.count == 2)

        // A duplicate/stale failure cannot restart the exhausted queue.
        coordinator.recordFailure(after: second.generation)
        #expect(coordinator.synchronizedSnapshot().currentSource == nil)
        coordinator.unregister(registration.token)
    }

    @Test
    func queueEditsPreserveThePlayingEntryAndClock() {
        var clock: CFTimeInterval = 100
        let coordinator = VideoBackgroundPlaybackCoordinator(now: { clock })
        let initial = coordinator.configure(sourceTexts: ["/tmp/first.mp4", "/tmp/second.mp4"], quality: "1080p")
        coordinator.advance(after: initial.generation)
        let registration = coordinator.register { _ in }
        coordinator.setPlayerRunning(true, for: registration.token)
        clock += 5
        let playing = coordinator.synchronizedSnapshot()

        for queue in [
            ["/tmp/first.mp4", "/tmp/second.mp4", "/tmp/third.mp4"],
            ["/tmp/third.mp4", "/tmp/second.mp4", "/tmp/first.mp4"],
            ["/tmp/second.mp4", "/tmp/first.mp4"]
        ] {
            let edited = coordinator.configure(sourceTexts: queue, quality: "1080p")
            #expect(edited.currentSource == playing.currentSource)
            #expect(edited.generation == playing.generation)
            #expect(edited.position == 5)
        }
        clock += 2
        #expect(coordinator.synchronizedSnapshot().position == 7)
    }

    @Test
    func qualityChangeFreezesTheSavedPlayheadUntilReplacementIsReady() {
        var clock: CFTimeInterval = 100
        let coordinator = VideoBackgroundPlaybackCoordinator(now: { clock })
        let initial = coordinator.configure(sourceTexts: ["/tmp/first.mp4", "/tmp/second.mp4"], quality: "1080p")
        coordinator.advance(after: initial.generation)
        let registration = coordinator.register { _ in }
        coordinator.setPlayerRunning(true, for: registration.token)
        clock += 5
        let playing = coordinator.synchronizedSnapshot()

        let edited = coordinator.configure(sourceTexts: ["/tmp/first.mp4", "/tmp/second.mp4"], quality: "720p")
        #expect(edited.currentSource == playing.currentSource)
        #expect(edited.generation != playing.generation)
        #expect(edited.position == 5)
        clock += 20
        coordinator.advance(after: playing.generation)
        #expect(coordinator.synchronizedSnapshot().position == 5)
        coordinator.setPlayerRunning(true, for: registration.token)
        clock += 2
        #expect(coordinator.synchronizedSnapshot().position == 7)
    }

    @Test
    func queueEditsPreserveDuplicateOccurrenceAndUpdateLoopMode() {
        var clock: CFTimeInterval = 100
        let coordinator = VideoBackgroundPlaybackCoordinator(now: { clock })
        let initial = coordinator.configure(sourceTexts: ["/tmp/first.mp4", "/tmp/first.mp4"], quality: "1080p")
        coordinator.advance(after: initial.generation)
        let registration = coordinator.register { _ in }
        coordinator.setPlayerRunning(true, for: registration.token)
        clock += 5
        let playing = coordinator.synchronizedSnapshot()

        let reordered = coordinator.configure(
            sourceTexts: ["/tmp/third.mp4", "/tmp/first.mp4", "/tmp/first.mp4"], quality: "1080p"
        )
        #expect(reordered.index == 2)
        #expect(reordered.generation == playing.generation)
        #expect(reordered.position == 5)
        let single = coordinator.configure(sourceTexts: ["/tmp/first.mp4"], quality: "1080p")
        #expect(single.index == 0)
        #expect(single.generation != playing.generation)
        #expect(single.position == 5)
        clock += 20
        #expect(coordinator.synchronizedSnapshot().position == 5)
    }

    @Test
    func addingQueueEntryAfterSingleLoopResetsTheManagedQueuePlayhead() {
        var clock: CFTimeInterval = 100
        let coordinator = VideoBackgroundPlaybackCoordinator(now: { clock })
        let initial = coordinator.configure(sourceTexts: ["/tmp/first.mp4"], quality: "1080p")
        let registration = coordinator.register { _ in }
        coordinator.setPlayerRunning(true, for: registration.token)
        clock += 125

        let queue = coordinator.configure(
            sourceTexts: ["/tmp/first.mp4", "/tmp/second.mp4"],
            quality: "1080p"
        )

        #expect(queue.index == 0)
        #expect(queue.currentSource == initial.currentSource)
        #expect(queue.position == 0)
        #expect(queue.generation != initial.generation)
        coordinator.setPlayerRunning(false, for: registration.token)
    }

    @Test
    func oneWindowFailureDoesNotAdvanceAPlayingPeer() {
        let coordinator = VideoBackgroundPlaybackCoordinator()
        let initial = coordinator.configure(
            sourceTexts: ["dQw4w9WgXcQ", "M7lc1UVf-VE"],
            quality: "1080p"
        )
        let failedWindow = coordinator.register { _ in }
        let healthyWindow = coordinator.register { _ in }
        coordinator.setPlayerRunning(true, for: failedWindow.token)
        coordinator.setPlayerRunning(true, for: healthyWindow.token)

        let disposition = coordinator.recordFailure(after: initial.generation, for: failedWindow.token)

        #expect(disposition == .deferred)
        #expect(coordinator.synchronizedSnapshot().currentSource == initial.currentSource)

        let finalDisposition = coordinator.recordFailure(after: initial.generation, for: healthyWindow.token)

        #expect(finalDisposition == .advanced)
        #expect(coordinator.synchronizedSnapshot().currentSource == .youTubeVideo(id: "M7lc1UVf-VE"))
        coordinator.unregister(failedWindow.token)
        coordinator.unregister(healthyWindow.token)
    }

    @Test
    func explicitSelectionRestartsAfterAPersistedQueueRotation() {
        var clock: CFTimeInterval = 100
        let coordinator = VideoBackgroundPlaybackCoordinator(now: { clock })
        let initial = coordinator.configure(sourceTexts: ["/tmp/first.mp4", "/tmp/second.mp4"], quality: "1080p")
        let registration = coordinator.register { _ in }
        coordinator.setPlayerRunning(true, for: registration.token)
        clock += 5
        let rotated = coordinator.configure(sourceTexts: ["/tmp/second.mp4", "/tmp/first.mp4"], quality: "1080p")
        #expect(rotated.currentSource == initial.currentSource)
        #expect(rotated.position == 5)

        let selected = coordinator.configure(
            sourceTexts: ["/tmp/second.mp4", "/tmp/first.mp4"], quality: "1080p", restart: true
        )
        #expect(selected.currentSource == rotated.sources.first)
        #expect(selected.index == 0)
        #expect(selected.position == 0)
        #expect(selected.generation != initial.generation)
        coordinator.advance(after: initial.generation)
        #expect(coordinator.synchronizedSnapshot() == selected)
    }

    @Test
    func staleFailureGenerationCannotAffectAReplacementQueue() {
        let coordinator = VideoBackgroundPlaybackCoordinator()
        let old = coordinator.configure(sourceTexts: ["dQw4w9WgXcQ"], quality: "1080p")
        let replacement = coordinator.configure(sourceTexts: ["M7lc1UVf-VE"], quality: "1080p")

        coordinator.recordFailure(after: old.generation)

        let current = coordinator.synchronizedSnapshot()
        #expect(current.generation == replacement.generation)
        #expect(current.currentSource == replacement.currentSource)
    }
}
