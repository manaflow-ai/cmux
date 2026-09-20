import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TmuxSessionReaperTests: XCTestCase {

    // MARK: - Ownership

    func testOrphansExcludesSessionsAnOpenWorkspaceOwns() {
        let live = ["azdevops", "azdevops-40", "reportmate-6", "orchard-13"]
        let owned: Set<String> = ["azdevops-40", "reportmate-6"]

        XCTAssertEqual(
            TmuxSessionReaper.orphans(live: live, ownedSessions: owned),
            ["azdevops", "orchard-13"]
        )
    }

    func testOrphansIsEmptyWhenEveryLiveSessionIsOwned() {
        let live = ["azdevops-40", "reportmate-6"]
        XCTAssertTrue(
            TmuxSessionReaper.orphans(live: live, ownedSessions: Set(live)).isEmpty
        )
    }

    func testEverySessionIsAnOrphanWhenNothingIsRegistered() {
        let live = ["azdevops", "reportmate-4"]
        XCTAssertEqual(
            TmuxSessionReaper.orphans(live: live, ownedSessions: []),
            live
        )
    }

    /// Ownership is exact, not prefix-based. `azdevops` being owned must not protect
    /// `azdevops-40`, and vice versa — they are independent sessions.
    func testOwnershipDoesNotMatchByPrefix() {
        let live = ["azdevops", "azdevops-40", "azdevops-75"]

        XCTAssertEqual(
            TmuxSessionReaper.orphans(live: live, ownedSessions: ["azdevops"]),
            ["azdevops-40", "azdevops-75"],
            "Owning the base name must not protect suffixed siblings"
        )
        XCTAssertEqual(
            TmuxSessionReaper.orphans(live: live, ownedSessions: ["azdevops-40"]),
            ["azdevops", "azdevops-75"],
            "Owning a suffixed session must not protect the base name"
        )
    }

    func testOrphansPreservesLiveOrdering() {
        let live = ["zeta", "alpha", "mid"]
        XCTAssertEqual(
            TmuxSessionReaper.orphans(live: live, ownedSessions: ["mid"]),
            ["zeta", "alpha"]
        )
    }

    // MARK: - Session-name derivation

    /// Instance 1 is the bare directory basename — the wrappers only append a suffix
    /// above 1, so predicting "-1" would never match anything live.
    func testSessionNameForFirstInstanceIsBareBasename() {
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps", instanceIndex: 1),
            "azdevops"
        )
    }

    func testSessionNameAppendsInstanceIndexAboveOne() {
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps", instanceIndex: 52),
            "azdevops-52"
        )
    }

    /// Must match `slugify()` in claude-remote exactly (`tr '[:upper:]' '[:lower:]' |
    /// tr ' .' '-'`); any divergence silently predicts a name that is never live.
    func testSessionNameFoldsSpacesAndDotsToHyphens() {
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/tmp/My Project.v2", instanceIndex: 1),
            "my-project-v2"
        )
    }

    func testSessionNameIgnoresTrailingSlash() {
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/Personal/", instanceIndex: 1),
            "personal"
        )
    }

    func testSessionNameIsEmptyForDegenerateDirectory() {
        XCTAssertTrue(TmuxSessionReaper.sessionName(directory: "", instanceIndex: 1).isEmpty)
    }

    /// The recovery pass intersects predicted names with the live list, so a workspace
    /// whose session is not running contributes nothing — this is what stops recovery
    /// from spawning a fresh agent in a genuinely idle workspace.
    func testPredictedNameOnlyRecoversWhenSessionIsLive() {
        let live: Set<String> = ["azdevops", "orchard-18"]

        XCTAssertTrue(live.contains(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps", instanceIndex: 1)
        ))
        XCTAssertFalse(live.contains(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/Idle", instanceIndex: 1)
        ))
    }

    /// Registration is cleared on restart, so right after a crash-relaunch the owned set
    /// is empty while sessions are still live. Prediction is what keeps those from being
    /// reported as orphans and offered up for killing.
    func testDerivedNamesProtectLiveSessionsWhenNothingIsRegistered() {
        let live = ["azdevops", "azdevops-52", "stale-thing"]
        let derived: Set<String> = [
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps", instanceIndex: 1),
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps", instanceIndex: 52),
        ]

        XCTAssertEqual(
            TmuxSessionReaper.orphans(live: live, ownedSessions: derived),
            ["stale-thing"],
            "Only the session no workspace would ever claim is an orphan"
        )
    }

    // MARK: - Kill targeting

    /// The `=` prefix is the whole safety property. A bare `-t azdevops` resolves by
    /// exact name, then prefix, then fnmatch — so without it, killing `azdevops`
    /// could take `azdevops-40` with it.
    func testKillTargetsExactSessionName() {
        XCTAssertEqual(
            TmuxSessionReaper.killArguments(for: "azdevops"),
            ["kill-session", "-t", "=azdevops"]
        )
    }

    func testKillArgumentsAnchorNamesThatArePrefixesOfOthers() {
        let args = TmuxSessionReaper.killArguments(for: "azdevops")
        XCTAssertEqual(args.last, "=azdevops")
        XCTAssertNotEqual(args.last, "azdevops", "Bare target would match by prefix")
    }

    func testKillArgumentsHandleNamesWithSuffixes() {
        XCTAssertEqual(
            TmuxSessionReaper.killArguments(for: "orchard-13"),
            ["kill-session", "-t", "=orchard-13"]
        )
    }

    // MARK: - Environment probing

    /// Absent tmux must be inert, not a crash: a GUI app does not inherit the user's
    /// shell PATH, so this path is reachable in normal use.
    func testKillIsNoOpForEmptySessionName() {
        XCTAssertFalse(TmuxSessionReaper.kill(""))
    }

    func testLiveSessionsNeverReturnsBlankNames() {
        // Runs against whatever tmux state the machine happens to be in — the point is
        // that parsing never yields empty entries, which would make every owned-set
        // comparison meaningless.
        for name in TmuxSessionReaper.liveSessions() {
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(name.hasPrefix(" "))
            XCTAssertFalse(name.hasSuffix(" "))
        }
    }
}

// MARK: - Title-based lane names

/// The *-remote wrappers name a lane from the workspace TITLE (see `cmux-lane-session`
/// in the Setup repo), because the instance index is a per-host counter: one workspace
/// can be instance 17 on one Mac and 1 on another. Prediction must follow the same rule
/// or reattach misses live lanes and the orphan reaper offers them up for killing.
final class TmuxLaneNameTests: XCTestCase {

    func testCustomTitleNamesTheLaneRegardlessOfInstance() {
        for instance in [1, 17] {
            XCTAssertEqual(
                TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps",
                                              title: "Vantage Dev", instanceIndex: instance,
                                              agent: .claude),
                "vantage-dev"
            )
        }
    }

    func testCodexLaneKeepsItsPrefix() {
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps",
                                          title: "Vantage Dev", instanceIndex: 17, agent: .codex),
            "cx-vantage-dev"
        )
    }

    func testPunctuationFoldsToSingleHyphens() {
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps",
                                          title: "Build Errors & Warnings", instanceIndex: 18,
                                          agent: .claude),
            "build-errors-warnings"
        )
    }

    func testDuplicateTitleSuffixBecomesPartOfTheName() {
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps",
                                          title: "Vantage Dev (10)", instanceIndex: 10,
                                          agent: .claude),
            "vantage-dev-10"
        )
    }

    /// A workspace titled after its repo keeps the basename name, so claude-launch and
    /// anything else addressing lanes by directory keeps working.
    func testRepoTitledLaneKeepsTheBasenameName() {
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/GitHub/rodchristiansen/apps/cmux",
                                          title: "rodchristiansen · cmux", instanceIndex: 1,
                                          agent: .claude),
            "cmux"
        )
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/GitHub/rodchristiansen/apps/cmux",
                                          title: "rodchristiansen · cmux (2)", instanceIndex: 2,
                                          agent: .claude),
            "cmux-2"
        )
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/Personal/Nutrition",
                                          title: "Personal - Nutrition", instanceIndex: 1,
                                          agent: .claude),
            "nutrition"
        )
    }

    func testEmptyTitleFallsBackToTheLegacyName() {
        XCTAssertEqual(
            TmuxSessionReaper.sessionName(directory: "/Users/rod/Developer/AzDevOps",
                                          title: "", instanceIndex: 17, agent: .claude),
            "azdevops-17"
        )
    }

    /// Sessions started before the rename rule still carry the legacy name, so the
    /// candidates cover both spellings and neither is reported as an orphan.
    func testCandidatesProtectBothTitleAndLegacySessions() {
        let candidates = TmuxSessionReaper.sessionNames(
            directory: "/Users/rod/Developer/AzDevOps", title: "Vantage Dev",
            instanceIndex: 17, agent: .claude
        )
        XCTAssertEqual(candidates.first, "vantage-dev", "The current rule is tried first")
        XCTAssertEqual(
            TmuxSessionReaper.orphans(live: ["vantage-dev", "azdevops-17", "stale"],
                                      ownedSessions: Set(candidates)),
            ["stale"]
        )
    }
}

// MARK: - Bounded subprocess runs

/// The lane-snapshot timer used to run `tmux list-sessions` on the main thread and
/// block in `waitUntilExit`, whose nested run loop re-entered SwiftUI layout and froze
/// the app. A run must return within its timeout whatever the child does.
final class TmuxSessionReaperRunTests: XCTestCase {

    func testRunReturnsOutputOfAQuickCommand() {
        let out = TmuxSessionReaper.run("/bin/echo", ["lane"], timeout: 5)
        XCTAssertEqual(out?.trimmingCharacters(in: .whitespacesAndNewlines), "lane")
    }

    func testRunGivesUpOnAHungCommandWithinItsTimeout() {
        let started = Date()
        let out = TmuxSessionReaper.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testRunReturnsNilForAFailingCommand() {
        XCTAssertNil(TmuxSessionReaper.run("/usr/bin/false", [], timeout: 5))
    }
}
