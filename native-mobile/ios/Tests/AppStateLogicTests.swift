import Testing
@testable import CmuxNative

struct MacListStateTests {
    @Test func failedLoadWithoutCacheIsAnErrorNotFirstRun() {
        #expect(MacListState(loaded: false, hostCount: 0, error: "offline") == .failed("offline"))
    }

    @Test func cachedMacsStayVisibleWhenReloadFails() {
        #expect(MacListState(loaded: false, hostCount: 2, error: "offline") == .macs)
    }

    @Test func loadedEmptyListIsFirstRun() {
        #expect(MacListState(loaded: true, hostCount: 0, error: nil) == .noMac)
    }

    @Test func nothingYetIsLoading() {
        #expect(MacListState(loaded: false, hostCount: 0, error: nil) == .loading)
    }
}

struct ForegroundRecoveryTests {
    @Test func silentConnectedLinkIsReplaced() {
        #expect(ForegroundRecovery.action(phase: .connected, probeSucceeded: false) == .reconnect)
    }

    @Test func answeringLinkOnlyRefreshes() {
        #expect(ForegroundRecovery.action(phase: .connected, probeSucceeded: true) == .refresh)
    }

    @Test func reconnectingOrOfflineLinkReconnectsAtOnce() {
        #expect(ForegroundRecovery.action(phase: .reconnecting, probeSucceeded: false) == .reconnect)
        #expect(ForegroundRecovery.action(phase: .offline("x"), probeSucceeded: false) == .reconnect)
    }

    @Test func firstConnectIsLeftAlone() {
        #expect(ForegroundRecovery.action(phase: .connecting, probeSucceeded: false) == .wait)
    }
}

struct DiffPayloadTests {
    @Test func readsTheTruncatedFlag() {
        let reply: JSONValue = ["diff": "diff --git a/x b/x\n+a\n", "truncated": true]
        let payload = DiffPayload(reply: reply)
        #expect(payload.truncated)
        #expect(payload.text.hasPrefix("diff --git"))
    }

    @Test func missingFlagMeansComplete() {
        #expect(DiffPayload(reply: ["diff": "x\n"]).truncated == false)
    }

    @Test func countsLinesIncludingACutLastLine() {
        #expect(DiffPayload.lineCount("a\nb\n") == 2)
        #expect(DiffPayload.lineCount("a\nb\nc") == 3)
        #expect(DiffPayload.lineCount("") == 0)
    }
}
