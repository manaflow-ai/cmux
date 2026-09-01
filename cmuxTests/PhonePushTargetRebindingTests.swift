import CmuxPhonePush
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct PhonePushTargetRebindingTests {
    @MainActor
    @Test func pendingPushesFollowAChangedPairingTarget() {
        var latestSnapshot: [PhonePushRequestEnvelope] = []
        let queue = PhonePushSerialDeliveryQueue(
            startsImmediately: false,
            pendingChanged: { latestSnapshot = $0 },
            sender: { _ in .accepted(sent: 1, devices: 1, pruned: 0) }
        )
        let first = Self.envelope(
            "00000000-0000-4000-8000-000000000001"
        )
        let second = Self.envelope(
            "00000000-0000-4000-8000-000000000002"
        )
        #expect(queue.enqueue(first))
        #expect(queue.enqueue(second))

        queue.rebindPending { envelope in
            PhonePushRequestEnvelope(
                correlationID: envelope.correlationID,
                expirationEpochSeconds: envelope.expirationEpochSeconds,
                body: envelope.body,
                coalescingID: envelope.coalescingID,
                expectedAccountID: envelope.expectedAccountID,
                expectedSessionGeneration: envelope.expectedSessionGeneration,
                targetBundleIdentifier: "dev.cmux.app.beta"
            )
        }

        #expect(latestSnapshot.map(\.targetBundleIdentifier) == [
            "dev.cmux.app.beta",
            "dev.cmux.app.beta",
        ])
    }

    @MainActor
    @Test func rebindSkipsOnlyTheInFlightQueueSlot() async {
        var latestSnapshot: [PhonePushRequestEnvelope] = []
        let started = AsyncStream.makeStream(of: String.self)
        let releaseFirst = AsyncStream.makeStream(of: Void.self)
        var callCount = 0
        let queue = PhonePushSerialDeliveryQueue(
            startsImmediately: false,
            pendingChanged: { latestSnapshot = $0 },
            sender: { envelope in
                callCount += 1
                started.continuation.yield(envelope.targetBundleIdentifier ?? "")
                if callCount == 1 {
                    for await _ in releaseFirst.stream.prefix(1) {}
                }
                return .accepted(sent: 1, devices: 1, pruned: 0)
            }
        )
        let first = Self.envelope("same-correlation", body: Data([1]))
        let second = Self.envelope("same-correlation", body: Data([2]))
        #expect(queue.enqueue(first))
        #expect(queue.enqueue(second))
        queue.start()

        var startedIterator = started.stream.makeAsyncIterator()
        #expect(await startedIterator.next() == "com.cmux.app")

        queue.rebindPending { envelope in
            PhonePushRequestEnvelope(
                correlationID: envelope.correlationID,
                expirationEpochSeconds: envelope.expirationEpochSeconds,
                body: envelope.body,
                coalescingID: envelope.coalescingID,
                expectedAccountID: envelope.expectedAccountID,
                expectedSessionGeneration: envelope.expectedSessionGeneration,
                targetBundleIdentifier: "dev.cmux.app.beta"
            )
        }
        #expect(latestSnapshot.map(\.targetBundleIdentifier) == [
            "com.cmux.app",
            "dev.cmux.app.beta",
        ])

        releaseFirst.continuation.yield()
        #expect(await startedIterator.next() == "dev.cmux.app.beta")
        await queue.waitUntilIdle()
    }

    @MainActor
    @Test func unresolvedTargetQueueHoldsEventsUntilPairingCompletes() async {
        var delivered: [PhonePushRequestEnvelope] = []
        let queue = PhonePushSerialDeliveryQueue(
            startsImmediately: true,
            sender: { envelope in
                delivered.append(envelope)
                return .accepted(sent: 1, devices: 1, pruned: 0)
            }
        )
        queue.stop()
        let unresolved = PhonePushRequestEnvelope(
            correlationID: "waiting-for-pairing",
            expirationEpochSeconds: 1_750_000_120,
            body: Data(),
            targetBundleIdentifier: nil
        )
        #expect(queue.enqueue(unresolved))
        #expect(delivered.isEmpty)

        queue.rebindPending { envelope in
            PhonePushRequestEnvelope(
                correlationID: envelope.correlationID,
                expirationEpochSeconds: envelope.expirationEpochSeconds,
                body: envelope.body,
                coalescingID: envelope.coalescingID,
                expectedAccountID: envelope.expectedAccountID,
                expectedSessionGeneration: envelope.expectedSessionGeneration,
                targetBundleIdentifier: "dev.cmux.app.beta"
            )
        }
        queue.start()
        await queue.waitUntilIdle()
        #expect(delivered.map(\.targetBundleIdentifier) == ["dev.cmux.app.beta"])
    }

    private static func envelope(
        _ correlationID: String,
        body: Data = Data()
    ) -> PhonePushRequestEnvelope {
        PhonePushRequestEnvelope(
            correlationID: correlationID,
            expirationEpochSeconds: 1_750_000_120,
            body: body,
            targetBundleIdentifier: "com.cmux.app"
        )
    }
}
