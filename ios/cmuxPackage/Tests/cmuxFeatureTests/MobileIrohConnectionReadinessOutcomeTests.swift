import CMUXMobileCore
import Testing
@testable import cmuxFeature

struct MobileIrohConnectionReadinessOutcomeTests {
    @Test func successfulOutcomesDoNotReportFailureKinds() {
        #expect(MobileIrohConnectionReadinessOutcome.inactive.failureKind == nil)
        #expect(MobileIrohConnectionReadinessOutcome.ready.failureKind == nil)
    }

    @Test func failedOutcomeReportsItsFailureKind() {
        let error = MobileIrohRuntimePreparationError(
            diagnosticFailureKind: .endpointUnavailable,
            retryAfterSeconds: 1
        )
        #expect(
            MobileIrohConnectionReadinessOutcome.failed(error).failureKind
                == .endpointUnavailable
        )
    }
}
