import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private func makeMediaPlaybackDiscardSnapshot(
    isCapturingMedia: Bool = false,
    hasAudibleMedia: Bool = false
) -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
    BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
        isClosing: false,
        isVisibleInUI: false,
        shouldRenderWebView: true,
        hasPendingRemoteNavigation: false,
        hasCurrentURL: true,
        isLoading: false,
        webViewIsLoading: false,
        hasActiveMainFrameProvisionalNavigation: false,
        isDownloading: false,
        activeDownloadCount: 0,
        preferredDeveloperToolsVisible: false,
        isDeveloperToolsVisible: false,
        isElementFullscreenActive: false,
        isReactGrabActive: false,
        isVisualAutomationCaptureActive: false,
        hasPopups: false,
        isCapturingMedia: isCapturingMedia,
        hasAudibleMedia: hasAudibleMedia
    )
}

@MainActor
private func withMediaPlaybackHiddenWebViewDiscardPolicyEnabled(
    _ body: (UserDefaults) throws -> Void
) throws {
    let suiteName = "com.cmux.BrowserMediaPlaybackAudioActivityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set(
        BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay,
        forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    try body(defaults)
}

@MainActor
@Suite(.serialized)
struct BrowserMediaPlaybackAudioActivityTests {
    @Test func activeSilentMediaPlaybackDrivesPlaybackStateWithoutAudioGlyph() {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }

        panel.applyMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: false)

        #expect(panel.isPlayingMedia)
        #expect(panel.isPlayingAudio == false)
    }

    @Test func activeSilentMediaPlaybackDoesNotBlockHiddenWebViewDiscard() throws {
        try withMediaPlaybackHiddenWebViewDiscardPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let snapshot = makeMediaPlaybackDiscardSnapshot(hasAudibleMedia: false)

            #expect(manager.blockers(for: snapshot) == [])
        }
    }

    @Test func audibleMediaPlaybackDrivesAudioGlyphIndependentlyOfDiscardBlocker() {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }

        panel.applyMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: true)

        #expect(panel.isPlayingMedia)
        #expect(panel.isPlayingAudio)

        panel.applyMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: false)

        #expect(panel.isPlayingMedia)
        #expect(panel.isPlayingAudio == false)
    }

    @Test func audibleMediaPlaybackBlocksHiddenWebViewDiscard() throws {
        try withMediaPlaybackHiddenWebViewDiscardPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let snapshot = makeMediaPlaybackDiscardSnapshot(hasAudibleMedia: true)

            #expect(manager.blockers(for: snapshot) == ["media_playback"])
        }
    }

    @Test func mediaCaptureStillBlocksHiddenWebViewDiscard() throws {
        try withMediaPlaybackHiddenWebViewDiscardPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            let snapshot = makeMediaPlaybackDiscardSnapshot(isCapturingMedia: true)

            #expect(manager.blockers(for: snapshot) == ["media_capture"])
        }
    }
}
