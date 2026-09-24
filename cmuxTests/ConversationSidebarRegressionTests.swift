import CmuxAgentChat
import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct ConversationSidebarRegressionTests {
    private let projection = ConversationSidebarProjection()

    @Test
    func pendingClaudeAliasDeduplicatesAgainstHistoryIdentity() {
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        var record = AgentChatSessionRecord(
            sessionID: pendingID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            title: "Live conversation",
            pid: nil
        )
        record.rememberHookStoreSessionID(realSessionID)

        #expect(
            projection.liveSessionKey(for: record)
                == VaultLiveSessionKeys.key(kind: "claude", sessionID: realSessionID)
        )
    }

    @Test
    func registeredAgentKeepsConfiguredPresentation() throws {
        let registered = RegisteredSessionAgent(
            id: "pi",
            name: "Pi",
            iconAssetName: "AgentIcons/Pi"
        )
        let record = AgentChatSessionRecord(
            sessionID: "pi-session",
            agentKind: .other("pi"),
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            title: nil,
            pid: nil
        )

        let agentsByID = projection.presentationAgentsByID([.registered(registered)])
        let resolved = try #require(
            projection.presentationAgent(
                for: record,
                configuredAgentsByDirectory: ["": agentsByID],
                fallbackAgentsByID: [:]
            )
        )
        #expect(resolved == .registered(registered))
        #expect(resolved.displayName == "Pi")
        #expect(resolved.assetName == "AgentIcons/Pi")
    }

    @Test
    func endedRecordsDoNotLoadPresentationConfigForOldDirectories() {
        let live = AgentChatSessionRecord(
            sessionID: "live", agentKind: .claude, workspaceID: nil, surfaceID: nil,
            workingDirectory: "/repo/live", transcriptPath: nil, state: .idle,
            lastActivityAt: Date.distantPast, title: nil, pid: nil
        )
        let ended = AgentChatSessionRecord(
            sessionID: "ended", agentKind: .claude, workspaceID: nil, surfaceID: nil,
            workingDirectory: "/repo/old", transcriptPath: nil, state: .ended,
            lastActivityAt: Date.distantPast, title: nil, pid: nil
        )

        #expect(projection.livePresentationDirectoryKeys(for: [live, ended]) == ["", "/repo/live"])
    }

    @Test
    func projectLocalAgentPresentationWinsForItsLiveDirectory() throws {
        let global = RegisteredSessionAgent(id: "custom", name: "Global Custom")
        let local = RegisteredSessionAgent(
            id: "custom", name: "Project Custom", iconAssetName: "AgentIcons/Pi"
        )
        let record = AgentChatSessionRecord(
            sessionID: "custom-session", agentKind: .other("custom"),
            workspaceID: nil, surfaceID: nil, workingDirectory: "/repo/project",
            transcriptPath: nil, state: .idle, lastActivityAt: Date.distantPast,
            title: nil, pid: nil
        )
        let resolved = try #require(projection.presentationAgent(
            for: record,
            configuredAgentsByDirectory: [
                "": projection.presentationAgentsByID([.registered(global)]),
                "/repo/project": projection.presentationAgentsByID([.registered(local)]),
            ],
            fallbackAgentsByID: [:]
        ))
        #expect(resolved == .registered(local))
        #expect(resolved.displayName == "Project Custom")
        #expect(resolved.assetName == "AgentIcons/Pi")
    }

    @Test
    func expandedHistoryKeepsNewerStoreEntries() {
        let old = sessionEntry(id: "old", title: "old", modified: 10)
        let refreshed = sessionEntry(id: "same", title: "new metadata", modified: 30)
        let stale = sessionEntry(id: "same", title: "stale metadata", modified: 20)
        let olderDuplicate = sessionEntry(id: "same", title: "older duplicate", modified: 5)

        let merged = projection.recentHistory(
            initial: [refreshed],
            expanded: [stale, old, olderDuplicate]
        )
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })

        #expect(merged.map(\.id) == ["same", "old"])
        #expect(Set(byID.keys) == ["old", "same"])
        #expect(byID["same"]?.title == "new metadata")
    }

    @Test
    func visibleHistoryProjectionStopsAfterOneSentinel() {
        let first = sessionEntry(id: "first", title: "first", modified: 30)
        let open = sessionEntry(id: "open", title: "open", modified: 20)
        let second = sessionEntry(id: "second", title: "second", modified: 10)
        let result = projection.visibleHistoryEntries(
            source: [first, open, second],
            excludingOpenIDs: [VaultLiveSessionKeys.key(for: open)],
            limit: 1
        )

        #expect(result.entries.map(\.id) == ["first"])
        #expect(result.hasMore)
        #expect(
            projection.nextHistoryPerAgentLimit(
                current: SessionIndexStore.perAgentLimit
            ) == SessionIndexStore.perAgentLimit + projection.historyPagePerAgent
        )
    }

    @Test
    func providerFilterUsesIdentityRatherThanPresentation() {
        let registered = SessionAgent.registered(RegisteredSessionAgent(
            id: "custom", name: "Claude Code"
        ))
        #expect(projection.providerFilterMatches(agent: .claude, selectedProviderID: nil))
        #expect(projection.providerFilterMatches(agent: .codex, selectedProviderID: "codex"))
        #expect(!projection.providerFilterMatches(agent: registered, selectedProviderID: "claude"))
        #expect(projection.providerFilterMatches(agent: registered, selectedProviderID: "custom"))
    }

    @Test
    func providerFilterAppliesBeforeHistoryPageLimitAndSentinel() {
        let unrelated = sessionEntry(id: "unrelated", title: "other", modified: 50, agent: .claude)
        let open = sessionEntry(id: "open", title: "open", modified: 40, agent: .codex)
        let first = sessionEntry(id: "first", title: "first", modified: 30, agent: .codex)
        let second = sessionEntry(id: "second", title: "second", modified: 20, agent: .codex)
        let source = [unrelated, open, first, second]
        let openIDs: Set<String> = [VaultLiveSessionKeys.key(for: open)]
        let page = projection.visibleHistoryEntries(
            source: source, excludingOpenIDs: openIDs, limit: 1,
            selectedProviderID: "codex"
        )
        #expect(page.entries.map(\.id) == ["first"])
        #expect(page.hasMore)

        let expanded = projection.visibleHistoryEntries(
            source: source, excludingOpenIDs: openIDs, limit: 2,
            selectedProviderID: "codex"
        )
        #expect(expanded.entries.map(\.id) == ["first", "second"])
        #expect(!expanded.hasMore)

        let noMatches = projection.visibleHistoryEntries(
            source: source, excludingOpenIDs: openIDs, limit: 0,
            selectedProviderID: "grok"
        )
        #expect(noMatches.entries.isEmpty)
        #expect(!noMatches.hasMore)
        #expect(projection.visibleHistoryEntries(
            source: source, excludingOpenIDs: openIDs, limit: 0,
            selectedProviderID: "codex"
        ).hasMore)
    }

    @Test
    func providerOptionsIncludeLiveOnlyAgentsAndRetainAbsentSelection() {
        let custom = SessionAgent.registered(RegisteredSessionAgent(
            id: "custom", name: "Project Agent", iconAssetName: "AgentIcons/Pi"
        ))
        let options = projection.providerFilterOptions(
            agents: [custom, .codex, custom, .claude],
            preferredOrder: [.claude, .codex, .claude, .grok],
            selectedProviderID: "grok"
        )
        #expect(options.map(\.rawValue) == ["claude", "codex", "grok", "custom"])
        #expect(options.last == custom)

        let refreshed = projection.providerFilterOptions(
            agents: [.codex], preferredOrder: [.claude, .codex, custom],
            selectedProviderID: "custom"
        )
        #expect(refreshed.map(\.rawValue) == ["codex", "custom"])
        #expect(refreshed.last == custom)
    }

    @Test
    func currentProviderMetadataWinsOverPaginatedCache() {
        let stale = SessionAgent.registered(RegisteredSessionAgent(
            id: "custom", name: "Old Name"
        ))
        let current = SessionAgent.registered(RegisteredSessionAgent(
            id: "custom", name: "Current Name", iconAssetName: "AgentIcons/Pi"
        ))
        let options = projection.providerFilterOptions(
            agents: [current, stale],
            preferredOrder: [current],
            selectedProviderID: nil
        )

        #expect(options == [current])
        #expect(options.first?.displayName == "Current Name")
        #expect(options.first?.assetName == "AgentIcons/Pi")
    }

    @Test
    func paginatedHistoryExtendsCachedProviderOptions() {
        let custom = SessionAgent.registered(RegisteredSessionAgent(
            id: "paginated-custom", name: "Paginated Custom"
        ))
        let page = [
            sessionEntry(id: "older-custom", title: "older", modified: 10, agent: custom),
            sessionEntry(id: "older-codex", title: "older codex", modified: 9, agent: .codex),
        ]
        let cached = projection.mergingProviderAgents(page, into: ["claude": .claude])
        let options = projection.providerFilterOptions(
            agents: Array(cached.values),
            preferredOrder: [.claude, .codex],
            selectedProviderID: nil
        )

        #expect(Set(cached.keys) == ["claude", "codex", "paginated-custom"])
        #expect(options.map(\.rawValue) == ["claude", "codex", "paginated-custom"])
        #expect(options.last == custom)
    }

    @Test
    func historySectionRemainsReachableWhenInitialHistoryIsAllOpen() {
        let open = sessionEntry(id: "open", title: "open", modified: 20)
        let visible = projection.visibleHistoryEntries(
            source: [open],
            excludingOpenIDs: [VaultLiveSessionKeys.key(for: open)],
            limit: 24
        )

        #expect(visible.entries.isEmpty)
        #expect(!visible.hasMore)
        #expect(projection.canShowMoreHistory(
            hasMoreLoadedHistory: false, searchIsEmpty: true,
            canLoadMoreHistory: true, hasLoadedHistorySource: true
        ))
        #expect(projection.shouldShowHistorySection(
            hasVisibleHistory: false,
            canShowMoreHistory: true
        ))
        #expect(!projection.shouldShowHistorySection(
            hasVisibleHistory: false,
            canShowMoreHistory: false
        ))
    }

    @Test
    func emptyVaultDoesNotOfferHistoryExpansion() {
        #expect(!projection.canShowMoreHistory(
            hasMoreLoadedHistory: false, searchIsEmpty: true,
            canLoadMoreHistory: true, hasLoadedHistorySource: false
        ))
        #expect(!projection.shouldShowHistorySection(
            hasVisibleHistory: false, canShowMoreHistory: false
        ))
    }

    @Test
    func endedSessionAdvancesTypedHistoryRevision() async {
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        let sessionID = "sidebar-ended-session"
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID, hookEventName: .sessionStart, source: "claude",
            workspaceId: UUID().uuidString, surfaceId: UUID().uuidString,
            cwd: "/Users/example/project", receivedAt: Date(timeIntervalSince1970: 10)
        ))
        let before = service.sidebarRevisionSnapshot

        service.registry.update(sessionID: sessionID) { $0.state = .ended }

        let after = service.sidebarRevisionSnapshot
        #expect(after.liveRevision == before.liveRevision + 1)
        #expect(after.historyRevision == before.historyRevision + 1)
    }

    @Test
    func activityOnlyRecordChangesDoNotRebuildSidebarProjection() async {
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in }
        )
        let sessionID = "sidebar-refresh-session"
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            cwd: "/Users/example/project",
            receivedAt: Date(timeIntervalSince1970: 10)
        ))
        let before = service.sidebarRevisionSnapshot

        service.registry.update(sessionID: sessionID) {
            $0.lastActivityAt = Date(timeIntervalSince1970: 20)
        }
        #expect(service.sidebarRevisionSnapshot == before)

        var changes = service.sidebarChanges().makeAsyncIterator()
        #expect(await changes.next() == before)

        service.registry.update(sessionID: sessionID) {
            $0.title = "Updated title"
            $0.lastActivityAt = Date(timeIntervalSince1970: 30)
        }
        let after = service.sidebarRevisionSnapshot
        #expect(after.liveRevision == before.liveRevision + 1)
        #expect(after.historyRevision == before.historyRevision)
        #expect(await changes.next() == after)
    }

    @Test
    func activityBumpStillChangesPhoneDescriptorButNotSidebarProjection() {
        let previous = AgentChatSessionRecord(
            sessionID: "sidebar-phone-parity-session",
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            title: "Conversation",
            pid: nil
        )
        var current = previous
        current.lastActivityAt = Date(timeIntervalSince1970: 20)
        current.version = previous.version + 1

        // Phones keep receiving descriptorChanged on a version bump, as on main.
        #expect(AgentChatTranscriptService.descriptorChangedMeaningfully(previous: previous, current: current))
        #expect(!AgentChatTranscriptService.sidebarProjectionChangedMeaningfully(previous: previous, current: current))

        current.title = "Renamed"
        #expect(AgentChatTranscriptService.descriptorChangedMeaningfully(previous: previous, current: current))
        #expect(AgentChatTranscriptService.sidebarProjectionChangedMeaningfully(previous: previous, current: current))
    }

    @Test
    func refreshSchedulerKeepsReplacementOwnedAfterOlderTaskFinishes() async {
        let oldStarted = AsyncStream<Void>.makeStream()
        let oldGate = AsyncStream<Void>.makeStream()
        let oldFinished = AsyncStream<Void>.makeStream()
        let newStarted = AsyncStream<Void>.makeStream()
        let newGate = AsyncStream<Void>.makeStream()
        let newFinished = AsyncStream<Void>.makeStream()
        let newObservedCancellation = AsyncStream<Void>.makeStream()
        let scheduler = ConversationSidebarRefreshScheduler()

        scheduler.schedule {
            oldStarted.continuation.yield()
            for await _ in oldGate.stream { break }
            oldFinished.continuation.yield()
        }
        var oldStartedIterator = oldStarted.stream.makeAsyncIterator()
        _ = await oldStartedIterator.next()

        scheduler.schedule {
            newStarted.continuation.yield()
            for await _ in newGate.stream { break }
            if Task.isCancelled {
                newObservedCancellation.continuation.yield()
            }
            newFinished.continuation.yield()
        }
        var newStartedIterator = newStarted.stream.makeAsyncIterator()
        _ = await newStartedIterator.next()

        // The cancelled operation is allowed to finish after its replacement
        // has been installed. It must not clear the replacement's handle.
        oldGate.continuation.yield()
        oldGate.continuation.finish()
        var oldFinishedIterator = oldFinished.stream.makeAsyncIterator()
        _ = await oldFinishedIterator.next()

        scheduler.cancel()
        newGate.continuation.yield()
        newGate.continuation.finish()
        var newFinishedIterator = newFinished.stream.makeAsyncIterator()
        _ = await newFinishedIterator.next()
        newObservedCancellation.continuation.finish()
        var cancellationIterator = newObservedCancellation.stream.makeAsyncIterator()
        #expect(await cancellationIterator.next() != nil)

        oldStarted.continuation.finish()
        newStarted.continuation.finish()
    }

    private func sessionEntry(
        id: String,
        title: String,
        modified: TimeInterval,
        agent: SessionAgent = .claude
    ) -> SessionEntry {
        SessionEntry(
            id: id,
            agent: agent,
            sessionId: id,
            title: title,
            cwd: "/Users/example/project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: modified),
            fileURL: nil,
            specifics: .claude(
                model: nil,
                permissionMode: nil,
                configDirectoryForResume: nil
            )
        )
    }
}
