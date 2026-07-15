import CMUXMobileCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileBrowserPreviewObserverTests {
    @Test func demandGatesEmissionAndEnforcesOneSecondFloor() async {
        let connectionID = UUID()
        let surfaceID = UUID().uuidString
        var currentTime: TimeInterval = 100
        var captures: [MobileBrowserPreviewResolution] = []
        var emitted: [MobileBrowserPreviewFrame] = []
        let observer = MobileBrowserPreviewObserver(
            minimumInterval: 1,
            snapshot: { capturedSurfaceID, resolution, sequence in
                captures.append(resolution)
                return MobileBrowserPreviewFrame(
                    surfaceID: capturedSurfaceID,
                    sequence: sequence,
                    resolution: resolution,
                    title: "Docs",
                    url: "https://example.com",
                    imageData: Data([1, 2, 3]),
                    pixelWidth: 600,
                    pixelHeight: 400
                )
            },
            emit: { emitted.append($0) },
            now: { currentTime },
            delay: { _ in throw CancellationError() }
        )

        observer.noteContentChanged(surfaceID: surfaceID)
        #expect(captures.isEmpty)

        observer.replaceConnectionDemand(
            connectionID: connectionID,
            summary: MobileBrowserPreviewDemandSummary(demands: [
                MobileBrowserPreviewDemand(previewSurfaceIDs: [surfaceID]),
            ])
        )
        await observer.debugAwaitWorkForTesting(surfaceID: surfaceID)
        #expect(captures == [.preview])
        #expect(emitted.map(\.sequence) == [1])

        observer.noteContentChanged(surfaceID: surfaceID)
        await observer.debugAwaitWorkForTesting(surfaceID: surfaceID)
        #expect(captures == [.preview])

        currentTime += 1
        observer.noteContentChanged(surfaceID: surfaceID)
        await observer.debugAwaitWorkForTesting(surfaceID: surfaceID)
        #expect(captures == [.preview, .preview])
        #expect(emitted.map(\.sequence) == [1, 2])

        observer.replaceConnectionDemand(
            connectionID: connectionID,
            summary: MobileBrowserPreviewDemandSummary(demands: [])
        )
        currentTime += 1
        observer.noteContentChanged(surfaceID: surfaceID)
        #expect(captures == [.preview, .preview])
        #expect(!observer.debugDemandForTesting.hasDemand)
    }
}
