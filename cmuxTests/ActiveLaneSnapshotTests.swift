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
