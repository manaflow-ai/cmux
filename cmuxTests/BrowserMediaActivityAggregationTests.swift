import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the workspace-row media indicator's core rule: a device counts as
/// active on the sidebar row when *any* browser pane in the workspace reports it
/// active (GitHub issue #6100). Exercises the pure fold so the behavior is
/// verified without standing up a full Workspace/BrowserPanel/WKWebView graph.
@Suite struct BrowserMediaActivityAggregationTests {
    private func pane(
        audio: Bool = false,
        mic: Bool = false,
        camera: Bool = false
    ) -> BrowserMediaActivity {
        BrowserMediaActivity(isPlayingAudio: audio, isUsingMicrophone: mic, isUsingCamera: camera)
    }

    @Test func emptyWorkspaceHasNoActivity() {
        let aggregate = BrowserMediaActivity.aggregating([BrowserMediaActivity]())
        #expect(aggregate == BrowserMediaActivity())
        #expect(aggregate.isActive == false)
    }

    @Test func anyPanePlayingAudioMarksWorkspaceAudioActive() {
        let aggregate = BrowserMediaActivity.aggregating([pane(), pane(audio: true), pane()])
        #expect(aggregate.isPlayingAudio)
        #expect(aggregate.isUsingMicrophone == false)
        #expect(aggregate.isUsingCamera == false)
        #expect(aggregate.isActive)
    }

    @Test func devicesAggregateIndependentlyAcrossPanes() {
        let aggregate = BrowserMediaActivity.aggregating([
            pane(audio: true),
            pane(mic: true),
            pane(camera: true),
        ])
        #expect(aggregate.isPlayingAudio)
        #expect(aggregate.isUsingMicrophone)
        #expect(aggregate.isUsingCamera)
    }

    @Test func silentPanesStayInactive() {
        let aggregate = BrowserMediaActivity.aggregating([pane(), pane(), pane()])
        #expect(aggregate == BrowserMediaActivity())
        #expect(aggregate.isActive == false)
    }
}
