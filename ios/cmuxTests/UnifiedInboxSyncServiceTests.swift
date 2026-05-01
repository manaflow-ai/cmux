import Combine
import XCTest
@testable import cmux_DEV

@MainActor
final class UnifiedInboxSyncServiceTests: XCTestCase {
    func testWorkspaceUpdateRewritesCachedRow() async throws {
        let database = try AppDatabase.inMemory()
        let inboxCache = InboxCacheRepository(database: database)

        let subject = PassthroughSubject<[MobileInboxWorkspaceRow], Never>()
        let service = UnifiedInboxSyncService(
            inboxCacheRepository: inboxCache,
            publisherFactory: { _ in subject.eraseToAnyPublisher() }
        )

        let receivedLiveUpdate = expectation(description: "received live workspace update")
        var cancellable: AnyCancellable?
        cancellable = service.workspaceItemsPublisher
            .dropFirst()
            .sink { items in
                if items.first?.preview == "preview 2" {
                    receivedLiveUpdate.fulfill()
                }
            }

        service.connect(teamID: "team_123")
        subject.send([
            .fixture(
                workspaceID: "workspace_123",
                title: "orb / cmux",
                preview: "preview 1",
                latestEventSeq: 4,
                lastReadEventSeq: 2,
                lastActivityAt: Date(timeIntervalSince1970: 20)
            )
        ])
        subject.send([
            .fixture(
                workspaceID: "workspace_123",
                title: "orb / cmux",
                preview: "preview 2",
                latestEventSeq: 5,
                lastReadEventSeq: 2,
                lastActivityAt: Date(timeIntervalSince1970: 30)
            )
        ])

        await fulfillment(of: [receivedLiveUpdate], timeout: 1.0)
        cancellable?.cancel()

        let cachedItems = try inboxCache.load()
        XCTAssertEqual(cachedItems.count, 1)
        XCTAssertEqual(cachedItems.first?.preview, "preview 2")
    }

    func testConnectDoesNotDropCachedWorkspaceRowsBeforeFirstLiveSnapshot() throws {
        let database = try AppDatabase.inMemory()
        let inboxCache = InboxCacheRepository(database: database)
        try inboxCache.save([
            UnifiedInboxItem(
                kind: .workspace,
                workspaceID: "workspace_123",
                machineID: "machine_123",
                teamID: "team_123",
                title: "orb / cmux",
                preview: "cached preview",
                unreadCount: 2,
                sortDate: Date(timeIntervalSince1970: 20),
                accessoryLabel: "Mac Mini",
                symbolName: "terminal",
                tmuxSessionName: "cmux-nightly",
                latestEventSeq: 5,
                lastReadEventSeq: 3,
                tailscaleHostname: "cmux-macmini.tail",
                tailscaleIPs: ["100.64.0.10"]
            )
        ])

        let liveRows = CurrentValueSubject<WorkspaceLiveSyncSnapshot, Never>(.placeholder())
        let service = UnifiedInboxSyncService(
            inboxCacheRepository: inboxCache,
            snapshotPublisherFactory: { _ in liveRows.eraseToAnyPublisher() }
        )

        var emissions: [[UnifiedInboxItem]] = []
        let cancellable = service.workspaceItemsPublisher.sink { emissions.append($0) }

        service.connect(teamID: "team_123")

        XCTAssertEqual(emissions.first?.first?.workspaceID, "workspace_123")
        XCTAssertEqual(emissions.last?.first?.workspaceID, "workspace_123")
        cancellable.cancel()
    }

    func testAuthoritativeEmptyWorkspaceSnapshotClearsCachedWorkspaceRows() throws {
        let database = try AppDatabase.inMemory()
        let inboxCache = InboxCacheRepository(database: database)
        try inboxCache.save([
            UnifiedInboxItem(
                kind: .workspace,
                workspaceID: "workspace_123",
                machineID: "machine_123",
                teamID: "team_123",
                title: "orb / cmux",
                preview: "cached preview",
                unreadCount: 2,
                sortDate: Date(timeIntervalSince1970: 20),
                accessoryLabel: "Mac Mini",
                symbolName: "terminal",
                tmuxSessionName: "cmux-nightly",
                latestEventSeq: 5,
                lastReadEventSeq: 3,
                tailscaleHostname: "cmux-macmini.tail",
                tailscaleIPs: ["100.64.0.10"]
            )
        ])

        let liveRows = CurrentValueSubject<WorkspaceLiveSyncSnapshot, Never>(.authoritative([]))
        let service = UnifiedInboxSyncService(
            inboxCacheRepository: inboxCache,
            snapshotPublisherFactory: { _ in liveRows.eraseToAnyPublisher() }
        )

        var emissions: [[UnifiedInboxItem]] = []
        let cancellable = service.workspaceItemsPublisher.sink { emissions.append($0) }

        service.connect(teamID: "team_123")

        XCTAssertEqual(emissions.first?.first?.workspaceID, "workspace_123")
        XCTAssertEqual(emissions.last, [])
        XCTAssertEqual(try inboxCache.load(), [])
        cancellable.cancel()
    }
}
