import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ActiveLaneSnapshotTests: XCTestCase {

    private func lane(
        _ workspace: UUID = UUID(),
        session: String = "personal",
        directory: String = "~/Developer/Personal",
        title: String = "Personal"
    ) -> ActiveLaneSnapshot.Lane {
        ActiveLaneSnapshot.Lane(
            workspace: workspace,
            session: session,
            directory: directory,
            title: title
        )
    }

    private func candidate(
        _ workspace: UUID = UUID(),
        title: String = "Orchard",
        directory: String = "/Users/rod/Developer/GitHub/orchard",
        instanceIndex: Int = 1,
        registered: String? = nil
    ) -> ActiveLaneSnapshot.Candidate {
        ActiveLaneSnapshot.Candidate(
            workspace: workspace,
            title: title,
            directory: directory,
            instanceIndex: instanceIndex,
            registered: registered
        )
    }

    // MARK: - Capture

    /// The regression that made this feature report "nothing to restore" with a live
    /// session sitting right there: the workspace's sidebar instance index (56) does not
    /// match the live session's name (plain `azdevops`), so deriving the name finds
    /// nothing. Matching on the session's directory resolves it.
    func testLanesMatchesASessionWhoseNameDoesNotDeriveFromTheWorkspace() {
        let lanes = ActiveLaneSnapshot.lanes(
            from: [candidate(
                title: "AzDevOps - Vantage",
                directory: "/Users/rod/Developer/AzDevOps",
                instanceIndex: 56
            )],
            live: [(session: "azdevops", directory: "/Users/rod/Developer/AzDevOps")]
        )
        XCTAssertEqual(lanes.map(\.session), ["azdevops"])
    }

    /// A lane started as `claude-remote -n boards` has a name nothing can derive.
    func testLanesMatchesAnExplicitlyNamedLaneByDirectory() {
        let lanes = ActiveLaneSnapshot.lanes(
            from: [candidate(directory: "/Users/rod/Developer/GitHub/orchard")],
            live: [(
                session: "orchard-boards",
                directory: "/Users/rod/Developer/GitHub/orchard"
            )]
        )
        XCTAssertEqual(lanes.map(\.session), ["orchard-boards"])
    }

    func testLanesIgnoresWorkspacesWithNoLiveSession() {
        let lanes = ActiveLaneSnapshot.lanes(
            from: [candidate(title: "Personal", directory: "/Users/rod/Developer/Personal")],
            live: [(session: "orchard", directory: "/Users/rod/Developer/GitHub/orchard")]
        )
        XCTAssertTrue(lanes.isEmpty)
    }

    func testLanesPrefersAnExplicitRegistrationWhenItIsLive() {
        let lanes = ActiveLaneSnapshot.lanes(
            from: [candidate(
                directory: "/Users/rod/Developer/GitHub/orchard",
                registered: "orchard-boards"
            )],
            live: [
                (session: "orchard", directory: "/Users/rod/Developer/GitHub/orchard"),
                (session: "orchard-boards", directory: "/Users/rod/Developer/GitHub/orchard"),
            ]
        )
        XCTAssertEqual(lanes.map(\.session), ["orchard-boards"])
    }

    /// A registration left over from a session that has since died must not be recorded.
    func testLanesIgnoresARegistrationThatIsNoLongerLive() {
        let lanes = ActiveLaneSnapshot.lanes(
            from: [candidate(
                directory: "/Users/rod/Developer/GitHub/orchard",
                registered: "orchard-dead"
            )],
            live: [(session: "orchard", directory: "/Users/rod/Developer/GitHub/orchard")]
        )
        XCTAssertEqual(lanes.map(\.session), ["orchard"])
    }

    /// Falls back to the derived name when the session has since changed directory.
    func testLanesFallsBackToTheDerivedNameWhenTheDirectoryNoLongerMatches() {
        let lanes = ActiveLaneSnapshot.lanes(
            from: [candidate(directory: "/Users/rod/Developer/GitHub/orchard")],
            live: [(session: "orchard", directory: "/somewhere/else")]
        )
        XCTAssertEqual(lanes.map(\.session), ["orchard"])
    }

    /// Two workspaces on one directory must not both claim the single live session.
    func testLanesRecordsOneWorkspacePerSession() {
        let lanes = ActiveLaneSnapshot.lanes(
            from: [
                candidate(directory: "/Users/rod/Developer/GitHub/orchard"),
                candidate(directory: "/Users/rod/Developer/GitHub/orchard"),
            ],
            live: [(session: "orchard", directory: "/Users/rod/Developer/GitHub/orchard")]
        )
        XCTAssertEqual(lanes.count, 1)
    }

    /// Two workspaces on one directory with two live sessions get one each.
    func testLanesGivesEachWorkspaceItsOwnSessionWhenSeveralShareADirectory() {
        let lanes = ActiveLaneSnapshot.lanes(
            from: [
                candidate(directory: "/Users/rod/Developer/AzDevOps"),
                candidate(directory: "/Users/rod/Developer/AzDevOps"),
            ],
            live: [
                (session: "azdevops", directory: "/Users/rod/Developer/AzDevOps"),
                (session: "azdevops-40", directory: "/Users/rod/Developer/AzDevOps"),
            ]
        )
        XCTAssertEqual(Set(lanes.map(\.session)), ["azdevops", "azdevops-40"])
    }

    func testLanesIsEmptyWhenNoTmuxServerIsRunning() {
        XCTAssertTrue(ActiveLaneSnapshot.lanes(from: [candidate()], live: []).isEmpty)
    }

    // MARK: - Selection

    func testRestorableKeepsRecordedLanesThatAreOpenAndUnattached() {
        let a = UUID(), b = UUID()
        let snapshot = ActiveLaneSnapshot.Snapshot(
            ts: 1_786_000_000,
            lanes: [lane(a, session: "personal"), lane(b, session: "azdevops-2")]
        )

        let restorable = ActiveLaneSnapshot.restorable(
            snapshot: snapshot,
            openWorkspaces: [a, b],
            attached: []
        )

        XCTAssertEqual(restorable.map(\.session), ["personal", "azdevops-2"])
    }

    /// Re-running the command must not restart a lane it already brought back, which is
    /// what lets a partial restore simply be invoked again.
    func testRestorableSkipsWorkspacesThatAlreadyHaveALane() {
        let a = UUID(), b = UUID()
        let snapshot = ActiveLaneSnapshot.Snapshot(
            ts: 1_786_000_000,
            lanes: [lane(a, session: "personal"), lane(b, session: "azdevops-2")]
        )

        let restorable = ActiveLaneSnapshot.restorable(
            snapshot: snapshot,
            openWorkspaces: [a, b],
            attached: [a]
        )

        XCTAssertEqual(restorable.map(\.session), ["azdevops-2"])
    }

    /// A workspace removed from the sidebar while cmux was closed has nowhere to land.
    func testRestorableDropsLanesWhoseWorkspaceIsGone() {
        let present = UUID(), removed = UUID()
        let snapshot = ActiveLaneSnapshot.Snapshot(
            ts: 1_786_000_000,
            lanes: [lane(present, session: "personal"), lane(removed, session: "deleted-repo")]
        )

        let restorable = ActiveLaneSnapshot.restorable(
            snapshot: snapshot,
            openWorkspaces: [present],
            attached: []
        )

        XCTAssertEqual(restorable.map(\.session), ["personal"])
    }

    func testRestorableIsEmptyForAnEmptySnapshot() {
        let snapshot = ActiveLaneSnapshot.Snapshot(ts: 1_786_000_000, lanes: [])
        XCTAssertTrue(
            ActiveLaneSnapshot.restorable(
                snapshot: snapshot,
                openWorkspaces: [UUID()],
                attached: []
            ).isEmpty
        )
    }

    // MARK: - Round trip

    func testSnapshotSurvivesAWriteAndReadCycle() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("last-active-lanes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let snapshot = ActiveLaneSnapshot.Snapshot(
            ts: 1_786_000_000,
            lanes: [
                lane(session: "personal", directory: "~/Developer/Personal", title: "Personal"),
                lane(session: "azdevops-2", directory: "~/Developer/AzDevOps", title: "AzDevOps"),
            ]
        )

        XCTAssertTrue(ActiveLaneSnapshot.write(snapshot, to: url))
        XCTAssertEqual(ActiveLaneSnapshot.read(from: url), snapshot)
    }

    /// Writing into a directory that does not exist yet is the first-run case.
    func testWriteCreatesTheStateDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("nested/state", isDirectory: true)
        let url = dir.appendingPathComponent("last-active-lanes.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(
            ActiveLaneSnapshot.write(
                ActiveLaneSnapshot.Snapshot(ts: 1, lanes: [lane()]),
                to: url
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// An empty snapshot has to be written, not skipped: leaving the previous file in
    /// place would offer to restore lanes the user has since closed.
    func testEmptySnapshotIsPersistedRatherThanLeavingStaleContent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("last-active-lanes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        ActiveLaneSnapshot.write(
            ActiveLaneSnapshot.Snapshot(ts: 1, lanes: [lane(session: "personal")]),
            to: url
        )
        ActiveLaneSnapshot.write(ActiveLaneSnapshot.Snapshot(ts: 2, lanes: []), to: url)

        XCTAssertEqual(ActiveLaneSnapshot.read(from: url)?.lanes, [])
    }

    func testReadReturnsNilWhenNoSnapshotHasBeenWritten() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("absent.json")
        XCTAssertNil(ActiveLaneSnapshot.read(from: url))
    }

    func testReadReturnsNilForCorruptContent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("last-active-lanes.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("not json".utf8).write(to: url)

        XCTAssertNil(ActiveLaneSnapshot.read(from: url))
    }
}
