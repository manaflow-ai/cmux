import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct ProcessSnapshotCentralizationTests {
    @Test
    func synchronousCompatibilityCaptureIsIncludedInProofMetrics() {
        let metrics = ProcessPerformanceMetrics(enabled: true)

        let snapshot = CmuxTopProcessSnapshot.captureSynchronouslyForCompatibility(
            includeProcessDetails: true,
            includeCMUXScope: true,
            metrics: metrics,
            captureWithProof: { includeProcessDetails, includeCMUXScope in
                (
                    CmuxTopProcessSnapshot(
                        processes: [],
                        sampledAt: Date(timeIntervalSince1970: 101),
                        includesProcessDetails: includeProcessDetails,
                        includesCMUXScope: includeCMUXScope
                    ),
                    .libproc
                )
            }
        )

        let proof = metrics.snapshot().processSnapshots
        #expect(snapshot.hasCMUXScope)
        #expect(proof.captureStarted == 1)
        #expect(proof.captureCompleted == 1)
        #expect(proof.inFlight == 0)
        #expect(proof.maximumInFlight == 1)
    }
}
