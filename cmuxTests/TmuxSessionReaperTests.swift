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
