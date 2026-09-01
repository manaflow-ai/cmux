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

    private static func envelope(_ correlationID: String) -> PhonePushRequestEnvelope {
        PhonePushRequestEnvelope(
            correlationID: correlationID,
            expirationEpochSeconds: 1_750_000_120,
            body: Data(),
            targetBundleIdentifier: "com.cmux.app"
        )
    }
}
