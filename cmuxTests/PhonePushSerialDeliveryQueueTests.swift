import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct PhonePushSerialDeliveryQueueTests {
    @MainActor
    @Test func inFlightOlderEventCannotCompleteAfterNewerEvent() async throws {
        let probe = FirstDeliveryGate()
        let queue = PhonePushSerialDeliveryQueue {
            await probe.deliver($0)
        }
        let first = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001"
        )
        let second = requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002"
        )

        #expect(queue.enqueue(first))
        #expect(queue.enqueue(second))
        await probe.waitForCount(1)
        #expect(
            await probe.correlationIDs
                == [first.correlationID]
        )

        await probe.releaseFirst()
        await probe.waitForCount(2)
        #expect(
            await probe.correlationIDs
                == [first.correlationID, second.correlationID]
        )
    }

    @MainActor
    @Test func declaredTwoHundredEventBurstDoesNotCoalesceOrDrop() async {
        let probe = RecordingDeliveryProbe()
        let queue = PhonePushSerialDeliveryQueue {
            await probe.deliver($0)
        }
        let envelopes = (0..<200).map {
            requestEnvelope(
                correlationID: String(
                    format: "00000000-0000-4000-8000-%012d",
                    $0
                )
            )
        }

        for envelope in envelopes {
            #expect(queue.enqueue(envelope))
        }
        await probe.waitForCount(envelopes.count)

        #expect(
            await probe.correlationIDs
                == envelopes.map(\.correlationID)
        )
    }

    @MainActor
    @Test func queueIsBoundedAndReportsOverflow() {
        let queue = PhonePushSerialDeliveryQueue(
            capacity: 2,
            sender: { _ in .accepted(sent: 1, devices: 1, pruned: 0) }
        )

        #expect(queue.enqueue(requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001"
        )))
        #expect(queue.enqueue(requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000002"
        )))
        #expect(!queue.enqueue(requestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000003"
        )))
    }

    @Test func queuedEventCannotRebindToTheNextSignedInAccount() {
        let envelope = PhonePushRequestEnvelope(
            correlationID: "00000000-0000-4000-8000-000000000001",
            expirationEpochSeconds: 1_750_000_120,
            body: Data(),
            expectedAccountID: "account-a"
        )
        let original = AuthenticatedSessionSnapshot(
            generation: 1,
            accountID: "account-a",
            accessToken: "access-a",
            refreshToken: "refresh-a"
        )
        let replacement = AuthenticatedSessionSnapshot(
            generation: 2,
            accountID: "account-b",
            accessToken: "access-b",
            refreshToken: "refresh-b"
        )

        #expect(envelope.belongs(to: original))
        #expect(!envelope.belongs(to: replacement))
    }

    private func requestEnvelope(
        correlationID: String
    ) -> PhonePushRequestEnvelope {
        PhonePushRequestEnvelope(
            correlationID: correlationID,
            expirationEpochSeconds: 1_750_000_120,
            body: Data()
        )
    }
}

private actor RecordingDeliveryProbe {
    private var values: [String] = []
    private var countWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var correlationIDs: [String] { values }

    func deliver(
        _ envelope: PhonePushRequestEnvelope
    ) -> PhonePushHTTPResult {
        values.append(envelope.correlationID)
        resumeSatisfiedWaiters()
        return .accepted(sent: 1, devices: 1, pruned: 0)
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let ready = countWaiters.filter { values.count >= $0.target }
        countWaiters.removeAll { values.count >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private actor FirstDeliveryGate {
    private var values: [String] = []
    private var firstRelease:
        CheckedContinuation<Void, Never>?
    private var countWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var firstWasReleased = false

    var correlationIDs: [String] { values }

    func deliver(
        _ envelope: PhonePushRequestEnvelope
    ) async -> PhonePushHTTPResult {
        values.append(envelope.correlationID)
        resumeSatisfiedWaiters()
        if values.count == 1, !firstWasReleased {
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
        }
        return .accepted(sent: 1, devices: 1, pruned: 0)
    }

    func waitForCount(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func releaseFirst() {
        firstWasReleased = true
        firstRelease?.resume()
        firstRelease = nil
    }

    private func resumeSatisfiedWaiters() {
        let ready = countWaiters.filter { values.count >= $0.target }
        countWaiters.removeAll { values.count >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
