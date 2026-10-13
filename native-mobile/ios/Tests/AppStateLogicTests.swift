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

struct TabTitleTests {
    private func tab(title: String?, cwd: String?, name: String? = nil) -> DaemonTab {
        DaemonTab(surface: 7, kind: "pty", name: name, title: title, size: nil, dead: nil, pinned: nil, cwd: cwd, gitBranch: nil)
    }

    @Test func homeFolderShellReadsTerminal() {
        #expect(tab(title: "~", cwd: "/Users/aziz").displayTitle == "Terminal")
    }

    @Test func folderTitleUsesTheFolderName() {
        #expect(tab(title: "~/code/cmux", cwd: "/Users/aziz/code/cmux").displayTitle == "cmux")
    }

    @Test func programTitleWins() {
        #expect(tab(title: "vim notes.md", cwd: "/Users/aziz").displayTitle == "vim notes.md")
    }

    @Test func promptTitleFallsBackToTheFolder() {
        #expect(tab(title: "aziz@mac:~/code/cmux", cwd: "/Users/aziz/code/cmux").displayTitle == "cmux")
    }
}

struct TerminalSessionCacheTests {
    @Test func keepsTheMostRecent() {
        #expect(TerminalSessionCache.evictions(recent: [1, 2, 3, 4, 5, 6], keep: 4) { _ in false } == [1, 2])
    }

    @Test func neverDropsAnAttachedSession() {
        #expect(TerminalSessionCache.evictions(recent: [1, 2, 3, 4, 5, 6], keep: 4) { $0 == 1 } == [2])
    }

    @Test func underTheLimitKeepsAll() {
        #expect(TerminalSessionCache.evictions(recent: [1, 2], keep: 4) { _ in false }.isEmpty)
    }
}

struct LaunchHostTests {
    private func host(_ id: String, online: Bool?) -> APIClient.Host {
        APIClient.Host(id: id, name: id, platform: "macos", online: online, lastSeen: nil)
    }

    @Test func savedChoiceWinsEvenWhenOffline() {
        let hosts = [host("a", online: true), host("b", online: false)]
        #expect(hosts.launchHost(selectedID: "b")?.id == "b")
    }

    @Test func withoutAChoiceAnOnlineMacBeatsAnOfflineOne() {
        let hosts = [host("old", online: false), host("mini", online: true)]
        #expect(hosts.launchHost(selectedID: nil)?.id == "mini")
    }

    @Test func aForgottenChoiceFallsBackToAnOnlineMac() {
        let hosts = [host("old", online: false), host("mini", online: true)]
        #expect(hosts.launchHost(selectedID: "unpaired")?.id == "mini")
    }

    @Test func allOfflineFallsBackToTheFirst() {
        let hosts = [host("a", online: nil), host("b", online: false)]
        #expect(hosts.launchHost(selectedID: nil)?.id == "a")
    }
}

struct AutoSwitchHostTests {
    private func host(_ id: String, online: Bool?) -> APIClient.Host {
        APIClient.Host(id: id, name: id, platform: "macos", online: online, lastSeen: nil)
    }

    @Test func staleAutomaticPickMovesToTheOnlineMac() {
        let fresh = [host("a", online: false), host("b", online: true)]
        #expect(fresh.autoSwitch(selectedID: nil, currentID: "a", currentConnected: false)?.id == "b")
    }

    @Test func aConnectedMacStays() {
        let fresh = [host("a", online: false), host("b", online: true)]
        #expect(fresh.autoSwitch(selectedID: nil, currentID: "a", currentConnected: true) == nil)
    }

    @Test func theUsersChoiceStaysEvenWhenOffline() {
        let fresh = [host("a", online: false), host("b", online: true)]
        #expect(fresh.autoSwitch(selectedID: "a", currentID: "a", currentConnected: false) == nil)
    }

    @Test func noConnectionPicksTheLaunchHost() {
        let fresh = [host("a", online: false), host("b", online: true)]
        #expect(fresh.autoSwitch(selectedID: nil, currentID: nil, currentConnected: false)?.id == "b")
    }

    @Test func alreadyOnTheBestMacDoesNothing() {
        let fresh = [host("a", online: false), host("b", online: true)]
        #expect(fresh.autoSwitch(selectedID: nil, currentID: "b", currentConnected: false) == nil)
    }
}

struct PinnedTerminalOrderTests {
    private func tab(_ surface: Int, pinned: Bool?, kind: String? = "pty") -> DaemonTab {
        DaemonTab(surface: surface, kind: kind, name: nil, title: nil, size: nil, dead: nil, pinned: pinned, cwd: nil, gitBranch: nil)
    }

    @Test func pinnedTerminalsComeFirstInTheirOrder() {
        let tabs = [tab(1, pinned: nil), tab(2, pinned: true), tab(3, pinned: false), tab(4, pinned: true)]
        #expect(DaemonTab.terminalsPinnedFirst(tabs).map(\.surface) == [2, 4, 1, 3])
    }

    @Test func browserTabsAreLeftOut() {
        let tabs = [tab(1, pinned: true, kind: "browser"), tab(2, pinned: nil)]
        #expect(DaemonTab.terminalsPinnedFirst(tabs).map(\.surface) == [2])
    }
}
