import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
