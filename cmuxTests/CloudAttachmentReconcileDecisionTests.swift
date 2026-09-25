import CmuxCloudTui
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A refresh pass must never tear down a working attachment because the
/// resolution lookup, which rides the same link, could not answer.
@Suite("Cloud attachment reconcile decision")
struct CloudAttachmentReconcileDecisionTests {
    private typealias Decision = CloudAttachmentReconcileDecision

    @Test
    func attachedStreamsSurviveLookupsThatCannotAnswer() {
        let closed = CloudTuiSurfaceIDResolution.retryable("transport closed before response", failure: .transportUnavailable)
        #expect(Decision.decide(phase: .attached, resolution: closed) == .keep)
        #expect(Decision.decide(phase: .attached, resolution: .noPlacement) == .keep)
        #expect(!Decision.decide(phase: .attached, resolution: closed).needsRetry)
    }

    @Test
    func unattachedStreamsAreFencedAndRetried() {
        for phase in [CloudTuiManualMirrorPhase.idle, .connecting, .disconnected] {
            let decision = Decision.decide(phase: phase, resolution: .retryable("lane busy", failure: .notReady))
            #expect(decision == .fence(.unresolved("lane busy")), "\(phase)")
            #expect(decision.needsRetry)
            #expect(Decision.decide(phase: phase, resolution: .noPlacement).needsRetry)
        }
    }

    @Test
    func authoritativeAnswersApplyToEveryPhase() {
        for phase in [CloudTuiManualMirrorPhase.attached, .disconnected, .connecting] {
            #expect(Decision.decide(phase: phase, resolution: .resolved(23)) == .rebind(surfaceID: 23))
            #expect(Decision.decide(phase: phase, resolution: .exited) == .exited)
        }
    }
}
