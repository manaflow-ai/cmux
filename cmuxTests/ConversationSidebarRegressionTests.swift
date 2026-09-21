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
    func endedSessionPublishesHistoryRefreshNotification() async {
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

        await confirmation("ended session refreshes Vault history") { refreshed in
            let observer = NotificationCenter.default.addObserver(
                forName: .agentChatSessionHistoryDidChange, object: service, queue: nil
            ) { _ in refreshed() }
            defer { NotificationCenter.default.removeObserver(observer) }
            service.registry.update(sessionID: sessionID) { $0.state = .ended }
        }
    }

    @Test
    func recordChangesPublishSidebarRefreshNotification() async {
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

        await confirmation("agent chat record update refreshes local projections") { refreshed in
            let observer = NotificationCenter.default.addObserver(
                forName: .agentChatSessionRecordsDidChange,
                object: service,
                queue: nil
            ) { _ in
                refreshed()
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            service.registry.update(sessionID: sessionID) {
                $0.title = "Updated title"
                $0.lastActivityAt = Date(timeIntervalSince1970: 20)
            }
        }
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
