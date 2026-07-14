import Foundation
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AgentNotificationReliableDeliveryTests: XCTestCase {
    func testSerializesMultipleCallersOffMainActor() async {
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }

        let deliveries = (0..<3).map { index in
            Task { @MainActor in
                await AgentNotificationDelivery().enqueueReliably(
                    workspaceID: UUID(), surfaceID: UUID(), title: "Reliable \(index)",
                    subtitle: "", body: "", category: nil, pending: false
                )
            }
        }
        await waitForReliableAdmissionBlock(bus)

        bus.drainForBackpressure()

        for delivery in deliveries {
            let result = await delivery.value
            XCTAssertEqual(result, .accepted)
        }
        let queuedTitles = bus.notificationQueueStateForTesting().1
        let reliableTitles = queuedTitles.filter { $0.hasPrefix("Reliable ") }
        XCTAssertEqual(reliableTitles.count, 3)
        XCTAssertEqual(Set(reliableTitles), ["Reliable 0", "Reliable 1", "Reliable 2"])
        let identities = bus.notificationIdentityStateForTesting()
        let reliableIdentities = queuedTitles.enumerated().compactMap { index, title in
            title.hasPrefix("Reliable ") ? identities[index] : nil
        }
        XCTAssertEqual(Set(reliableIdentities.map(\.0)).count, 3)
        XCTAssertEqual(reliableIdentities.map(\.1), reliableIdentities.map(\.1).sorted())
    }

    func testCannotCrossClearBoundary() async {
        let bus = TerminalMutationBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: tabId, surfaceId: surfaceId, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }
        let preClear = Task { @MainActor in
            await AgentNotificationDelivery().enqueueReliably(
                workspaceID: tabId, surfaceID: surfaceId, title: "Must not survive clear",
                subtitle: "", body: "", category: nil, pending: false
            )
        }
        await waitForReliableAdmissionBlock(bus)

        bus.enqueueClearNotifications(forTabId: tabId, surfaceId: surfaceId)

        let preClearResult = await preClear.value
        XCTAssertEqual(preClearResult, .cancelled)
        XCTAssertFalse(bus.notificationQueueStateForTesting().1.contains("Must not survive clear"))
        let postClearResult = await AgentNotificationDelivery().enqueueReliably(
            workspaceID: tabId, surfaceID: surfaceId, title: "Accepted after clear",
            subtitle: "", body: "", category: nil, pending: false
        )
        XCTAssertEqual(postClearResult, .accepted)
        XCTAssertEqual(bus.notificationQueueStateForTesting().1, ["Accepted after clear"])
    }

    func testSurfaceAddressedAdmissionCannotCrossWorkspaceClearBoundary() async {
        let bus = TerminalMutationBus.shared
        let tabId = UUID()
        let surfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: tabId, surfaceId: surfaceId, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }
        let preClear = Task { @MainActor in
            await AgentNotificationDelivery().enqueueReliably(
                workspaceID: tabId, surfaceID: surfaceId, title: "Must not resurrect after workspace clear",
                subtitle: "", body: "", category: nil, pending: false
            )
        }
        await waitForReliableAdmissionBlock(bus)

        bus.enqueueClearNotifications(forTabId: tabId)
        bus.drainForBackpressure()

        let preClearResult = await preClear.value
        XCTAssertEqual(preClearResult, .cancelled)
        XCTAssertFalse(bus.notificationQueueStateForTesting().1.contains("Must not resurrect after workspace clear"))
    }

    func testMigratesAcrossSessionTransfer() async {
        let bus = TerminalMutationBus.shared
        let oldTabId = UUID()
        let newTabId = UUID()
        let oldSurfaceId = UUID()
        let newSurfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: oldTabId, surfaceId: oldSurfaceId, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }
        let preTransfer = Task { @MainActor in
            await AgentNotificationDelivery().enqueueReliably(
                workspaceID: oldTabId, surfaceID: oldSurfaceId, title: "Must survive transfer once",
                subtitle: "", body: "", category: nil, pending: false
            )
        }
        await waitForReliableAdmissionBlock(bus)
        let transferTime = Date()

        bus.transferPendingNotifications(
            fromTabId: oldTabId, toTabId: newTabId, panelIdMap: [oldSurfaceId: newSurfaceId]
        )
        bus.drainForBackpressure()

        let preTransferResult = await preTransfer.value
        XCTAssertEqual(preTransferResult, .accepted)
        let titles = bus.notificationQueueStateForTesting().1
        XCTAssertEqual(titles.filter { $0 == "Must survive transfer once" }.count, 1)
        guard let reliableIndex = titles.firstIndex(of: "Must survive transfer once") else {
            return XCTFail("Transferred reliable notification was not admitted")
        }
        let identity = bus.notificationIdentityStateForTesting()[reliableIndex]
        XCTAssertEqual(identity.2, newTabId)
        XCTAssertEqual(identity.3, newSurfaceId)
        XCTAssertLessThanOrEqual(identity.1, transferTime)
    }

    func testUnmappedSurfaceSurvivesReliableAdmissionSessionTransfer() async {
        let bus = TerminalMutationBus.shared
        let oldTabId = UUID()
        let newTabId = UUID()
        let unmappedSurfaceId = UUID()
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: oldTabId, surfaceId: unmappedSurfaceId, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }
        let preTransfer = Task { @MainActor in
            await AgentNotificationDelivery().enqueueReliably(
                workspaceID: oldTabId, surfaceID: unmappedSurfaceId, title: "Must retain unmapped surface",
                subtitle: "", body: "", category: nil, pending: false
            )
        }
        await waitForReliableAdmissionBlock(bus)

        bus.transferPendingNotifications(fromTabId: oldTabId, toTabId: newTabId, panelIdMap: [:])
        bus.drainForBackpressure()

        let result = await preTransfer.value
        XCTAssertEqual(result, .accepted)
        let titles = bus.notificationQueueStateForTesting().1
        guard let index = titles.firstIndex(of: "Must retain unmapped surface") else {
            return XCTFail("Transferred reliable notification was not admitted")
        }
        let identity = bus.notificationIdentityStateForTesting()[index]
        XCTAssertEqual(identity.2, newTabId)
        XCTAssertEqual(identity.3, unmappedSurfaceId)
    }

    func testReliableAdmissionBacklogIsBounded() async {
        let bus = TerminalMutationBus.shared
        bus.discardPendingNotifications()
        bus.setDrainsSuspendedForTesting(true)
        defer { reset(bus) }
        for index in 0..<TerminalMutationBus.maximumPendingMutationCount {
            XCTAssertTrue(bus.enqueueNotification(
                tabId: UUID(), surfaceId: nil, title: "Seed \(index)", subtitle: "", body: ""
            ))
        }

        let deliveries = (0...TerminalMutationBus.maximumWaitingNotificationProducerCount).map { index in
            Task { @MainActor in
                await AgentNotificationDelivery().enqueueReliably(
                    workspaceID: UUID(), surfaceID: UUID(), title: "Bounded \(index)",
                    subtitle: "", body: "", category: nil, pending: false
                )
            }
        }
        await waitForReliableAdmissionBlock(bus)
        for _ in 0..<10_000 { await Task.yield() }

        bus.lock.lock()
        let admissionCount = bus.reliableAdmissionsById.count
        bus.lock.unlock()
        XCTAssertLessThanOrEqual(
            admissionCount,
            TerminalMutationBus.maximumWaitingNotificationProducerCount
        )

        bus.drainForBackpressure()
        bus.drainForBackpressure()
        var results: [AgentNotificationDeliveryResult] = []
        for delivery in deliveries { results.append(await delivery.value) }
        XCTAssertEqual(results.filter { $0 == .accepted }.count, 16)
        XCTAssertEqual(results.filter { $0 == .saturated }.count, 1)
        XCTAssertEqual(results.filter { $0 == .cancelled }.count, 0)
    }

    private func waitForReliableAdmissionBlock(_ bus: TerminalMutationBus) async {
        for _ in 0..<10_000 {
            if bus.reliablyWaitingNotificationProducerCountForTesting() == 1 { return }
            await Task.yield()
        }
        XCTFail("Reliable admission worker did not reach the capacity wait")
    }

    private func reset(_ bus: TerminalMutationBus) {
        bus.discardPendingNotifications()
        bus.drainForTesting()
        bus.setDrainsSuspendedForTesting(false)
    }
}
