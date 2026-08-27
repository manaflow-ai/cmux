import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserMediaPlaybackAudioActivityTests {
    @Test func activeSilentMediaPlaybackBlocksDiscardWithoutAudioGlyph() {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }

        panel.applyMediaPlaybackReport(frameID: "main", isPlaying: true, isAudible: false)

        #expect(panel.isPlayingMedia)
        #expect(panel.isPlayingAudio == false)
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
}
