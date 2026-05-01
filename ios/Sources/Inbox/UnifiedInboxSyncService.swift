import Combine
import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "inbox.sync")

@MainActor
protocol UnifiedInboxWorkspaceSyncing: AnyObject {
    var workspaceItemsPublisher: AnyPublisher<[UnifiedInboxItem], Never> { get }
    func connect(teamID: String)
}

@MainActor
final class UnifiedInboxSyncService: UnifiedInboxWorkspaceSyncing {
    private let inboxCacheRepository: InboxCacheRepository?
    private let workspaceLiveSync: WorkspaceLiveSyncing
    private let subject: CurrentValueSubject<[UnifiedInboxItem], Never>
    private var cancellables = Set<AnyCancellable>()
    private var activeTeamID: String?

    init(
        inboxCacheRepository: InboxCacheRepository?,
        workspaceLiveSync: WorkspaceLiveSyncing? = nil
    ) {
        self.inboxCacheRepository = inboxCacheRepository
        self.workspaceLiveSync = workspaceLiveSync ?? NoOpWorkspaceLiveSync()
        let cachedWorkspaceItems = (try? inboxCacheRepository?.load().filter { $0.kind == .workspace }) ?? []
        self.subject = CurrentValueSubject(cachedWorkspaceItems)
    }

    convenience init(
        inboxCacheRepository: InboxCacheRepository?,
        publisherFactory: @MainActor @escaping (String) -> AnyPublisher<[MobileInboxWorkspaceRow], Never>
    ) {
        self.init(
            inboxCacheRepository: inboxCacheRepository,
            workspaceLiveSync: ClosureWorkspaceLiveSync { teamID in
                publisherFactory(teamID)
                    .map { WorkspaceLiveSyncSnapshot.authoritative($0) }
                    .eraseToAnyPublisher()
            }
        )
    }

    convenience init(
        inboxCacheRepository: InboxCacheRepository?,
        snapshotPublisherFactory: @MainActor @escaping (String) -> AnyPublisher<WorkspaceLiveSyncSnapshot, Never>
    ) {
        self.init(
            inboxCacheRepository: inboxCacheRepository,
            workspaceLiveSync: ClosureWorkspaceLiveSync(publisherFactory: snapshotPublisherFactory)
        )
    }

    var workspaceItemsPublisher: AnyPublisher<[UnifiedInboxItem], Never> {
        subject.eraseToAnyPublisher()
    }

    func connect(teamID: String) {
        guard activeTeamID != teamID else { return }
        activeTeamID = teamID
        cancellables.removeAll()

        workspaceLiveSync.publisher(teamID: teamID)
            .map { snapshot in
                (
                    items: snapshot.rows.map { UnifiedInboxItem(workspaceRow: $0, teamID: teamID) },
                    isAuthoritative: snapshot.isAuthoritative
                )
            }
            .sink { [weak self] snapshot in
                self?.handleLiveWorkspaceItems(snapshot.items, isAuthoritative: snapshot.isAuthoritative)
            }
            .store(in: &cancellables)
    }

    private func handleLiveWorkspaceItems(_ items: [UnifiedInboxItem], isAuthoritative: Bool) {
        if shouldIgnoreSnapshot(items, isAuthoritative: isAuthoritative) {
            return
        }
        subject.send(items)
        guard let inboxCacheRepository else { return }

        do {
            try inboxCacheRepository.save(items)
        } catch {
            #if DEBUG
            log.error("Failed to persist live workspace inbox items: \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }

    private func shouldIgnoreSnapshot(_ items: [UnifiedInboxItem], isAuthoritative: Bool) -> Bool {
        !isAuthoritative && items.isEmpty && !subject.value.isEmpty
    }

    nonisolated static func mergeItems(
        conversationItems: [UnifiedInboxItem],
        workspaceItems: [UnifiedInboxItem]
    ) -> [UnifiedInboxItem] {
        sort(items: conversationItems + workspaceItems)
    }

    nonisolated static func sort(items: [UnifiedInboxItem]) -> [UnifiedInboxItem] {
        items.sorted { lhs, rhs in
            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }
            if lhs.kind != rhs.kind {
                return lhs.kind == .workspace && rhs.kind == .conversation
            }
            return lhs.id < rhs.id
        }
    }
}

@MainActor
private final class ClosureWorkspaceLiveSync: WorkspaceLiveSyncing {
    private let publisherFactory: @MainActor (String) -> AnyPublisher<WorkspaceLiveSyncSnapshot, Never>

    init(
        publisherFactory: @MainActor @escaping (String) -> AnyPublisher<WorkspaceLiveSyncSnapshot, Never>
    ) {
        self.publisherFactory = publisherFactory
    }

    func publisher(teamID: String) -> AnyPublisher<WorkspaceLiveSyncSnapshot, Never> {
        publisherFactory(teamID)
    }
}
