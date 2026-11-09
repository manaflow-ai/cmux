import CmuxCloud
import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Optimistic Cloud pane creation: the pane exists before the terminal, input
/// typed meanwhile reaches the terminal, and one request id owns retry and cancel.
@Suite("Cloud terminal pane reservation")
struct CloudTerminalPaneReservationTests {
    @Test
    func relayQueuesInputUntilARouterIsAttachedThenForwardsInOrder() async throws {
        let relay = CloudOptimisticInputRelay()
        relay.send(.bytes(Data("ls".utf8)))
        relay.send(.namedKey("enter"))
        #expect(relay.pendingCount == 2)

        let queue = DispatchQueue(label: "reservation-test")
        let router = CloudTuiManualIOInputRouter(surfaceID: 17, queue: queue)
        let connection = try CloudManualMirrorSocketFixture()
        defer { connection.close() }
        // Attaching flushes the queue into the router (which itself holds the
        // lines until a transport exists) and forwards later input directly.
        relay.attach(router)
        #expect(relay.pendingCount == 0)
        relay.send(.bytes(Data("pwd\n".utf8)))
        #expect(relay.pendingCount == 0)

        let transport = CloudTuiManualIOConnection(socketPath: connection.socketPath)
        defer { transport.close() }
        try await transport.start()
        router.setConnection(transport)
        let first = await connection.nextCommand(timeout: .seconds(2))
        let second = await connection.nextCommand(timeout: .seconds(2))
        let third = await connection.nextCommand(timeout: .seconds(2))
        #expect(first?.inputBytes == Data("ls".utf8))
        #expect(second?.cmd == "send-key")
        #expect(third?.inputBytes == Data("pwd\n".utf8))
        #expect(first?.surface == 17 && second?.surface == 17 && third?.surface == 17)
    }

    @Test
    func relayDiscardDropsQueuedInputAndALaterAttachResumesForwarding() {
        let relay = CloudOptimisticInputRelay()
        relay.send(.bytes(Data("typed too early".utf8)))
        relay.discard()
        #expect(relay.pendingCount == 0)
        relay.send(.bytes(Data("still discarded".utf8)))
        #expect(relay.pendingCount == 0)
        let router = CloudTuiManualIOInputRouter(surfaceID: 17)
        relay.attach(router)
        relay.send(.bytes(Data("after retry".utf8)))
        #expect(relay.pendingCount == 0)
    }

    @Test
    func relayBoundsTheQueue() {
        let relay = CloudOptimisticInputRelay()
        for _ in 0..<5_000 { relay.send(.bytes(Data([0x61]))) }
        #expect(relay.pendingCount == 4_096)
    }

    @Test
    func relayHandsQueuedInputToAnAdoptingDeviceRouterInOrder() async {
        let relay = CloudOptimisticInputRelay()
        relay.send(.bytes(Data("ls".utf8)))
        relay.send(.bytes(Data("\r".utf8)))

        let recorder = DeviceInputRecorder()
        let router = DeviceTerminalInputRouter(
            send: { await recorder.append($0) },
            onFailure: { _ in }
        )
        // A device mirror adopting a reserved pane must receive what was typed
        // before its terminal attached, then everything typed after.
        relay.attach(router)
        #expect(relay.pendingCount == 0)
        relay.send(.bytes(Data("pwd\r".utf8)))

        let expected = Data("ls\rpwd\r".utf8)
        let deadline = ContinuousClock.now + .seconds(2)
        while await recorder.bytes != expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.bytes == expected)
    }

    @Test @MainActor
    func devicePaneReservationsLeaveNamedKeysToGhostty() {
        // The device router sends bytes only, so a named-key resolver on a
        // device reservation would silently drop Enter, arrows and Tab.
        let device = SurfaceMachineID.device(SurfaceDeviceInstanceID(deviceID: "other-mac", tag: "default"))
        #expect(Workspace.reservationKeyNameResolver(for: device) == nil)
        #expect(Workspace.reservationKeyNameResolver(for: .cloud("reservation-fixture")) != nil)
    }

    @Test @MainActor
    func storeRoutesFailureToTheReservedPaneAndReplaysTheSameRequestOnRetry() async throws {
        let store = CloudPaneCreationFailureStore()
        let requestID = store.beginRequest()
        let resource = Self.resource()
        let completions = AsyncStream<Void>.makeStream()
        var completion = completions.stream.makeAsyncIterator()
        var creates = 0
        var projections = 0
        var inlineFailures = 0
        var starts = 0
        store.run(
            machine: resource.machine,
            requestID: requestID,
            create: { creates += 1; return resource },
            project: { resource in
                projections += 1
                if projections == 1 { throw CloudDiagnosticFailure.network }
                return (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onStart: { starts += 1 },
            onFinish: { completions.continuation.yield(()) },
            inlineFailure: { _ in inlineFailures += 1 },
            discardProjection: { _ in }
        )
        _ = await completion.next()
        // The failure lives in the pane, never on the workspace card.
        #expect(inlineFailures == 1)
        #expect(store.failure == nil)
        #expect(store.hasActiveRequests)

        store.retry(requestID: requestID)
        _ = await completion.next()
        #expect(creates == 1)
        #expect(projections == 2)
        #expect(starts == 2)
        #expect(!store.hasActiveRequests)
    }

    @Test @MainActor
    func closingTheReservedPaneCancelsOnlyItsRequest() async throws {
        let store = CloudPaneCreationFailureStore()
        let resource = Self.resource()
        let started = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        var finishes = 0
        var projections = 0
        let cancelledID = store.beginRequest()
        store.run(
            machine: resource.machine,
            requestID: cancelledID,
            create: {
                started.resolve(true)
                _ = await release.result
                return resource
            },
            project: { resource in
                projections += 1
                return (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onStart: {},
            onFinish: { finishes += 1 },
            inlineFailure: { _ in },
            discardProjection: { _ in }
        )
        let survivingID = store.beginRequest()
        let survivingDone = CloudLinkFirstValue<Bool>()
        store.run(
            machine: resource.machine,
            requestID: survivingID,
            create: { resource },
            project: { resource in
                (SurfaceProjection(resource: resource.id, workspaceID: UUID(), panelID: UUID()), false)
            },
            onStart: {},
            onFinish: { survivingDone.resolve(true) },
            inlineFailure: { _ in },
            discardProjection: { _ in }
        )
        _ = await started.result
        store.cancel(requestID: cancelledID)
        release.resolve(true)
        _ = await survivingDone.result
        try await Self.waitUntil { finishes == 1 }
        #expect(projections == 0)
        #expect(store.failure == nil)
        #expect(!store.hasActiveRequests)
    }

    @Test @MainActor
    func restoredPaneCapturesItsSavedAttachmentTarget() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { app.tearDown() }
            let workspace = app.workspace
            let sourceID = try #require(workspace.focusedPanelId)
            let pane = try #require(workspace.paneId(forPanelId: sourceID))
            let snapshot = try #require(workspace.sessionSnapshot(includeScrollback: false).panels.first)
            let record = SurfaceProjectionRecord(
                panelID: sourceID, resource: Self.resource().id,
                remoteWorkspaceID: "saved-workspace", remoteTabID: "saved-tab"
            )
            let panelID = try #require(workspace.reserveRestoredCloudTerminalPane(
                snapshot: snapshot, projection: record, inPane: pane
            ))
            let reservation = try #require(workspace.cloudPendingCreations[panelID])
            #expect(reservation.attachmentPlacement == SurfaceResourcePlacement(
                resource: record.resource, remoteWorkspaceID: record.remoteWorkspaceID,
                remoteTabID: record.remoteTabID
            ))
            #expect(reservation.remoteWorkspaceID == record.remoteWorkspaceID)
            #expect(reservation.remoteTabID == record.remoteTabID)
            #expect(workspace.machineOwningSurface(panelID) == record.resource.machine)
        }
    }

    @Test("Restored attachment validates the exact saved view after catalog changes",
          arguments: ["moved", "removed", "metadataMissing", "wrongTabReceipt", "wrongWorkspaceReceipt", "wrongResource", "wrongMachine"])
    @MainActor
    func restoredAttachmentRejectsChangedPlacement(change: String) throws {
        let catalog = SurfaceCatalog()
        var resource = Self.resource()
        let provider = CloudTerminalPlacementTestProvider(machine: resource.machine, catalog: catalog)
        catalog.register(provider)
        defer { catalog.unregister(machine: provider.machine) }
        let saved = SurfaceRemoteWorkspace(id: "saved-workspace", name: "Saved", index: 0, focused: false)
        let other = SurfaceRemoteWorkspace(id: "other-workspace", name: "Other", index: 1, focused: true)
        resource.remoteWorkspace = other
        resource.remoteViews = [
            SurfaceRemoteView(tabID: "other-tab", workspace: other),
            SurfaceRemoteView(tabID: "sibling-tab", workspace: saved),
            SurfaceRemoteView(tabID: "saved-tab", workspace: saved)
        ]
        catalog.upsert(resource, from: provider)
        try #require(catalog.resources[resource.id] == resource)
        let reservation = CloudTerminalPaneReservation(
            workspaceID: UUID(), panelID: UUID(), machine: resource.machine,
            attachmentPlacement: SurfaceResourcePlacement(
                resource: resource.id, remoteWorkspaceID: saved.id, remoteTabID: "saved-tab"
            )
        )
        let expected = SurfaceRemotePlacement(workspaceID: saved.id, tabID: "saved-tab")
        #expect(try reservation.validatedAttachmentPlacement(
            resourceID: resource.id, remoteTabID: "saved-tab", catalog: catalog
        ) == expected)

        var returnedPlacement = expected
        var returnedResourceID = resource.id
        switch change {
        case "moved": resource.remoteViews?[2].workspace = other
        case "removed": resource.remoteViews?.removeLast()
        case "metadataMissing": resource.remoteViews = nil
        case "wrongTabReceipt": returnedPlacement = SurfaceRemotePlacement(workspaceID: saved.id, tabID: "sibling-tab")
        case "wrongWorkspaceReceipt": returnedPlacement = SurfaceRemotePlacement(workspaceID: other.id, tabID: "saved-tab")
        case "wrongResource": returnedResourceID = SurfaceResourceID(machine: resource.machine, kind: .terminal, key: "other-terminal")
        case "wrongMachine": returnedResourceID = SurfaceResourceID(machine: .cloud("other-machine"), kind: .terminal, key: resource.id.key)
        default: Issue.record("Unknown placement change")
        }
        catalog.upsert(resource, from: provider)
        try #require(catalog.resources[resource.id] == resource)
        #expect(throws: CloudDiagnosticFailure.placement) {
            try reservation.validatedAttachmentPlacement(
                resourceID: returnedResourceID, remoteTabID: "saved-tab",
                materializedPlacement: returnedPlacement, catalog: catalog
            )
        }
    }

    @Test @MainActor
    func aNewCreationDoesNotMistakeItsSourceTabForTheAttachmentTarget() throws {
        let resource = Self.resource()
        let reservation = CloudTerminalPaneReservation(
            workspaceID: UUID(), panelID: UUID(), machine: resource.machine,
            sourcePlacement: CloudTerminalSourcePlacement(
                machine: resource.machine, remoteWorkspaceID: "workspace", remoteTabID: "source-tab"
            )
        )
        let created = SurfaceRemotePlacement(workspaceID: "workspace", tabID: "new-tab")
        #expect(reservation.attachmentPlacement == nil)
        #expect(try reservation.validatedAttachmentPlacement(
            resourceID: resource.id, remoteTabID: created.tabID,
            materializedPlacement: created, catalog: SurfaceCatalog()
        ) == created)
    }

    @Test("Exact restored replacement preserves saved identity while legacy inference remains available",
          arguments: [false, true])
    @MainActor
    func replacementKeepsSavedPlacementWhenRequested(preservingSavedPlacement: Bool) throws {
        let catalog = SurfaceCatalog()
        var resource = Self.resource()
        let provider = CloudTerminalPlacementTestProvider(machine: resource.machine, catalog: catalog)
        catalog.register(provider)
        defer { catalog.unregister(machine: provider.machine) }
        let other = SurfaceRemoteWorkspace(id: "other-workspace", name: "Other", index: 0, focused: true)
        resource.remoteViews = [SurfaceRemoteView(tabID: "other-tab", workspace: other)]
        catalog.upsert(resource, from: provider)
        try #require(catalog.resources[resource.id] == resource)
        let previous = SurfaceProjection(
            resource: resource.id, workspaceID: UUID(), panelID: UUID(),
            remoteWorkspaceID: "saved-workspace", remoteTabID: "saved-tab"
        )
        catalog.record(previous)
        let panelID = UUID()
        catalog.replaceProjection(
            previous, withPanel: panelID, in: previous.workspaceID,
            remotePlacement: nil, preservingSavedPlacement: preservingSavedPlacement
        )
        let replacement = catalog.projection(forPanel: panelID)
        #expect(catalog.projection(forPanel: previous.panelID) == nil)
        #expect(replacement?.resource == resource.id)
        #expect(replacement?.remoteWorkspaceID == (preservingSavedPlacement ? "saved-workspace" : other.id))
        #expect(replacement?.remoteTabID == (preservingSavedPlacement ? "saved-tab" : "other-tab"))
    }

    private static func resource() -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: .cloud("reservation-fixture"), kind: .terminal, key: "term_created"),
            title: "", detail: nil, lifecycle: .launching, agent: nil,
            remoteWorkspace: nil, remoteViews: [], port: nil, url: nil
        )
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

private actor DeviceInputRecorder {
    private(set) var bytes = Data()

    func append(_ data: Data) {
        bytes.append(data)
    }
}
