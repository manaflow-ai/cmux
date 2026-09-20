import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud terminal mutation lifecycle", .timeLimit(.minutes(1)))
struct CloudTerminalMutationLifecycleTests {
    @Test("Cancelling all turns keeps their predecessor chain until active work drains")
    func cancellationDoesNotReleaseSuccessorsEarly() async throws {
        let queue = CloudTerminalMutationQueue()
        let transport = CloudTerminalMutationTestTransport()
        var predecessorReturned = false
        var cancelledTurnRan = false
        let active = queue.enqueue {
            let data = try await transport.runTuiCommand(arguments: CloudTuiRequest("workspace.run"), deadline: .seconds(30))
            predecessorReturned = true
            return data
        }
        let cancelledTurn = queue.enqueue {
            cancelledTurnRan = true
            return Data()
        }
        defer { queue.cancelAll(); transport.release() }
        try #require(await transport.started.result == true)
        queue.cancelAll()
        #expect(active.isCancelled && cancelledTurn.isCancelled)
        let replacementTurn = queue.enqueue {
            #expect(predecessorReturned, "A fresh turn must remain behind the cancelled active transport")
            return Data("new".utf8)
        }
        transport.release(Data("late old reply".utf8))
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await cancelledTurn.value }
        #expect(try await replacementTurn.value == Data("new".utf8))
        await queue.waitForIdle()
        #expect(!cancelledTurnRan)
    }

    @Test("Provider retirement rejects late command results and subsequent mutations",
          arguments: ["suspend", "replace", "unregister"], ["session.snapshot", "workspace.run", "session.creation.resolve"])
    func commandAwaitIsFenced(change: String, operation: String) async throws {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        let transport = CloudTerminalMutationTestTransport()
        let lifecycle = provider.lifecycleGeneration
        let commands = CloudTerminalMutationCommandRunner(base: transport) {
            try provider.validateTerminalMutationLifecycle(lifecycle)
        }
        var published = false
        let task = provider.terminalMutationQueue.enqueue {
            _ = try await commands.runTuiCommand(arguments: CloudTuiRequest(operation), deadline: .seconds(30))
            _ = try await commands.runTuiCommand(arguments: CloudTuiRequest("pane.split"), deadline: .seconds(30))
            published = true
        }
        var replacement: CmuxTuiSurfaceProvider?
        defer {
            provider.suspendForFeatureFlag()
            replacement?.suspendForFeatureFlag()
            catalog.unregister(machine: provider.machine)
            transport.release()
        }
        try #require(await transport.started.result == true)
        switch change {
        case "suspend": provider.suspendForFeatureFlag()
        case "replace": replacement = makeProvider(catalog: catalog, machineID: provider.machineID)
        case "unregister": catalog.unregister(machine: provider.machine)
        default: Issue.record("Unknown lifecycle transition")
        }
        transport.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.commands == [operation])
        #expect(!published)
        #expect(provider.pendingRemoteCreations.isEmpty)
        #expect(catalog.resources.isEmpty)
    }

    @Test("Suspended and replaced providers reject both creation entrypoints before connecting",
          arguments: ["suspend", "replace", "unregister"])
    func staleProviderNeverConnects(change: String) async {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        var replacement: CmuxTuiSurfaceProvider?
        switch change {
        case "suspend": provider.suspendForFeatureFlag()
        case "replace": replacement = makeProvider(catalog: catalog, machineID: provider.machineID)
        case "unregister": catalog.unregister(machine: provider.machine)
        default: Issue.record("Unknown lifecycle transition")
        }
        defer {
            provider.suspendForFeatureFlag()
            replacement?.suspendForFeatureFlag()
            catalog.unregister(machine: provider.machine)
        }
        // The fixture has no client or hub. Reaching connection would throw a
        // transport error instead of this lifecycle cancellation.
        await #expect(throws: CancellationError.self) {
            try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: "workspace")
        }
        await #expect(throws: CancellationError.self) {
            try await provider.createTerminal(nearTabID: "tab", splitDirection: .right)
        }
    }

    @Test("A queued provider create cannot enter a replaced lifecycle",
          arguments: [false, true], ["resume", "replace"])
    func queuedCreationKeepsItsAdmittedLifecycle(layout: Bool, change: String) async throws {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        let transport = CloudTerminalMutationTestTransport()
        let blockingTurn = provider.terminalMutationQueue.enqueue {
            try await transport.runTuiCommand(arguments: CloudTuiRequest("workspace.run"), deadline: .seconds(30))
        }
        var replacement: CmuxTuiSurfaceProvider?
        defer {
            provider.suspendForFeatureFlag()
            replacement?.suspendForFeatureFlag()
            catalog.unregister(machine: provider.machine)
            transport.release()
        }
        try #require(await transport.started.result == true)
        let admitted = CloudLinkFirstValue<Bool>()
        let request = Task {
            admitted.resolve(true)
            if layout { return try await provider.createTerminal(nearTabID: "tab", splitDirection: .right) }
            return try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: "workspace")
        }
        try #require(await admitted.result == true)
        if change == "resume" {
            provider.suspendForFeatureFlag()
            provider.update(summary: provider.summary)
        } else {
            replacement = makeProvider(catalog: catalog, machineID: provider.machineID)
        }
        transport.release()
        _ = try? await blockingTurn.value
        await #expect(throws: CancellationError.self) { try await request.value }
    }

    @Test("Resume creates a new generation without reviving old queued turns")
    func suspensionInvalidatesQueuedWorkAcrossResume() async throws {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        let transport = CloudTerminalMutationTestTransport()
        let oldGeneration = provider.lifecycleGeneration
        var queuedRan = false
        let active = provider.terminalMutationQueue.enqueue {
            try await transport.runTuiCommand(arguments: CloudTuiRequest("workspace.run"), deadline: .seconds(30))
        }
        let queued = provider.terminalMutationQueue.enqueue { queuedRan = true }
        defer {
            provider.suspendForFeatureFlag()
            catalog.unregister(machine: provider.machine)
            transport.release()
        }
        try #require(await transport.started.result == true)
        provider.suspendForFeatureFlag()
        #expect(active.isCancelled && queued.isCancelled)
        provider.update(summary: provider.summary)
        #expect(throws: CancellationError.self) { try provider.validateTerminalMutationLifecycle(oldGeneration) }
        let generation = provider.lifecycleGeneration
        let next = provider.terminalMutationQueue.enqueue {
            try provider.validateTerminalMutationLifecycle(generation)
        }
        transport.release()
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
        try await next.value
        #expect(!queuedRan)
        await provider.stop()
    }

    @Test("Account teardown quiesces every provider before awaiting the first active turn")
    func registryQuiescesAllProvidersBeforeJoining() async throws {
        let catalog = SurfaceCatalog()
        let summaries = (0..<3).map { machine("lifecycle-\(UUID())-\($0)") }
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: summaries, limits: nil) },
            refreshProvider: { _, _ in },
            closeTransports: {},
            notificationCenter: NotificationCenter()
        )
        registry.start(catalog: catalog)
        _ = await registry.refresh(force: true)
        let providers = try summaries.map { try #require(registry.provider(machineID: $0.id)) }
        let cancellation = CloudLinkFirstValue<Bool>()
        let transports = providers.map { _ in CloudTerminalMutationTestTransport(cancelled: cancellation) }
        let active = zip(providers, transports).map { provider, transport in
            provider.terminalMutationQueue.enqueue {
                try await transport.runTuiCommand(arguments: CloudTuiRequest("workspace.run"), deadline: .seconds(30))
            }
        }
        defer { for transport in transports { transport.release() } }
        for transport in transports { try #require(await transport.started.result == true) }
        var finished = false
        let stop = Task { await registry.accessDidEnd(); finished = true }
        try #require(await cancellation.result == true)
        #expect(providers.allSatisfy(\.isFeatureSuspended))
        #expect(active.allSatisfy(\.isCancelled))
        #expect(providers.allSatisfy { catalog.provider(for: $0.machine) == nil })
        #expect(!finished, "Teardown must join the already-issued command")
        let resuming = CloudLinkFirstValue<Bool>()
        var resumed = false
        let signIn = Task {
            resuming.resolve(true)
            await registry.resumeAfterSignIn()
            resumed = true
        }
        try #require(await resuming.result == true)
        #expect(!resumed)
        #expect(await registry.providerRefreshingIfMissing(machineID: summaries[0].id) == nil)
        for transport in transports { transport.release() }
        for task in active { await #expect(throws: CancellationError.self) { try await task.value } }
        await stop.value
        #expect(finished)
        await signIn.value
        #expect(resumed)
        await registry.accessDidEnd()
    }

    @Test("Machine deletion cancels terminal turns before scheduling asynchronous cleanup")
    func deletionQuiescesProviderSynchronously() async throws {
        let catalog = SurfaceCatalog()
        let summary = machine("delete-\(UUID())")
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: [summary], limits: nil) },
            refreshProvider: { _, _ in }, closeTransports: {}, notificationCenter: NotificationCenter()
        )
        registry.start(catalog: catalog)
        _ = await registry.refresh(force: true)
        let provider = try #require(registry.provider(machineID: summary.id))
        var ran = false
        let queued = provider.terminalMutationQueue.enqueue { ran = true }
        registry.machineWasDeleted(summary.id)
        #expect(provider.isFeatureSuspended)
        #expect(queued.isCancelled)
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(!ran)
        await registry.accessDidEnd()
    }

    private func makeProvider(catalog: SurfaceCatalog, machineID: String = "mutation-\(UUID())") -> CmuxTuiSurfaceProvider {
        let provider = CmuxTuiSurfaceProvider(
            summary: machine(machineID),
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            catalog: catalog
        )
        catalog.register(provider)
        return provider
    }

    private func machine(_ id: String) -> VMSummary {
        VMSummary(id: id, provider: "freestyle", status: "running", image: "fixture", createdAt: 0, base: nil)
    }
}
