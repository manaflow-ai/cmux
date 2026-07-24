import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserDesignModeArtifactStoreTests {
    @Test @MainActor func browserPanelsRetainIndependentHandoffs() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(
            "cmux-design-mode-independent-handoff-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = BrowserDesignModeArtifactStore(directory: directory)
        let secondStore = BrowserDesignModeArtifactStore(directory: directory)
        let firstController = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            artifactStore: firstStore,
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(),
            canEnable: { true },
            clipboardWriter: { _ in true },
            onActivityChanged: {}
        )
        let secondController = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            artifactStore: secondStore,
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(),
            canEnable: { true },
            clipboardWriter: { _ in true },
            onActivityChanged: {}
        )
        let first = try await firstStore.saveContextJSON(Data("first".utf8), surfaceID: UUID())
        let second = try await secondStore.saveContextJSON(Data("second".utf8), surfaceID: UUID())

        #expect(try await firstController.deliverHandoff(
            prompt: "first",
            artifactPaths: [first.path],
            operation: 0
        ))
        #expect(try await secondController.deliverHandoff(
            prompt: "second",
            artifactPaths: [second.path],
            operation: 0
        ))

        for value in 0..<99 {
            _ = try await secondStore.saveScreenshot(
                Data([UInt8(value)]),
                surfaceID: UUID(),
                retention: .liveContext
            )
        }

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test @MainActor func clipboardHandoffLeaseSurvivesUntilSuccessfulReplacement() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(
            "cmux-design-mode-clipboard-lease-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDesignModeArtifactStore(directory: directory)
        var clipboardWriteSucceeds = true
        let controller = BrowserDesignModeController(
            surfaceID: UUID(),
            script: BrowserDesignModeScript(),
            promptFormatter: BrowserDesignModePromptFormatter(),
            artifactStore: store,
            javaScriptEvaluator: BrowserDesignModeJavaScriptEvaluator(),
            screenshotEvaluator: BrowserDesignModeScreenshotEvaluator(),
            canEnable: { true },
            clipboardWriter: { _ in clipboardWriteSucceeds },
            onActivityChanged: {}
        )
        let first = try await store.saveContextJSON(Data("first".utf8), surfaceID: UUID())

        #expect(try await controller.deliverHandoff(
            prompt: "first",
            artifactPaths: [first.path],
            operation: 0
        ))
        let sharedPathFailureMarkers = try handoffMarkerNames(in: directory)
        #expect(sharedPathFailureMarkers.count == 1)
        #expect(sharedPathFailureMarkers.first?.hasSuffix(first.lastPathComponent) == true)

        let failedCandidate = try await store.saveContextJSON(
            Data("failed".utf8),
            surfaceID: UUID()
        )
        clipboardWriteSucceeds = false
        await #expect(throws: BrowserScreenshotError.self) {
            _ = try await controller.deliverHandoff(
                prompt: "failed",
                artifactPaths: [failedCandidate.path],
                operation: 0
            )
        }
        #expect(try handoffMarkerNames(in: directory).count == 1)
        #expect(try handoffMarkerNames(in: directory)[0].hasSuffix(first.lastPathComponent))

        await #expect(throws: BrowserScreenshotError.self) {
            _ = try await controller.deliverHandoff(
                prompt: "failed shared path",
                artifactPaths: [first.path],
                operation: 0
            )
        }
        let markersAfterSharedPathFailure = try handoffMarkerNames(in: directory)
        #expect(markersAfterSharedPathFailure.count == 1)
        #expect(markersAfterSharedPathFailure.first?.hasSuffix(first.lastPathComponent) == true)

        let replacement = try await store.saveContextJSON(
            Data("replacement".utf8),
            surfaceID: UUID()
        )
        clipboardWriteSucceeds = true
        #expect(try await controller.deliverHandoff(
            prompt: "replacement",
            artifactPaths: [replacement.path],
            operation: 0
        ))
        #expect(try handoffMarkerNames(in: directory).count == 1)
        #expect(try handoffMarkerNames(in: directory)[0].hasSuffix(replacement.lastPathComponent))
    }

    @Test func pruningPinsOnlyLiveAnnotationContext() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-pinning-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDesignModeArtifactStore(directory: directory)
        let surfaceID = UUID()
        let pinned = try await store.saveScreenshot(
            Data([0]),
            surfaceID: surfaceID,
            retention: .liveContext
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: pinned.path
        )

        for value in 1...101 {
            _ = try await store.saveScreenshot(Data([UInt8(value)]), surfaceID: surfaceID)
        }
        #expect(FileManager.default.fileExists(atPath: pinned.path))

        await store.release(pinned)
        _ = try await store.saveScreenshot(Data([255]), surfaceID: surfaceID)
        #expect(!FileManager.default.fileExists(atPath: pinned.path))
    }

    @Test func releasingLiveAnnotationImmediatelyRestoresArtifactLimit() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-release-pruning-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDesignModeArtifactStore(directory: directory)
        let surfaceID = UUID()
        var pinned: [URL] = []

        for value in 0...100 {
            pinned.append(try await store.saveScreenshot(
                Data([UInt8(value)]),
                surfaceID: surfaceID,
                retention: .liveContext
            ))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 101)

        await store.release(pinned[0])

        #expect(!FileManager.default.fileExists(atPath: pinned[0].path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 100)
        for url in pinned.dropFirst() {
            await store.remove(url)
        }
    }

    @Test func releaseKeepsExistingHandoffPathReadable() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-release-path-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDesignModeArtifactStore(directory: directory)
        let expected = Data([0, 1, 2])
        let screenshotURL = try await store.saveScreenshot(
            expected,
            surfaceID: UUID(),
            retention: .liveContext
        )

        await store.release(screenshotURL)

        #expect(FileManager.default.fileExists(atPath: screenshotURL.path))
        #expect(try Data(contentsOf: screenshotURL) == expected)
    }

    @Test func releasedArtifactIsPrunableAcrossStoreInstances() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-cross-store-release-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstStore = BrowserDesignModeArtifactStore(
            directory: directory,
            liveContextSessionID: "current"
        )
        let secondStore = BrowserDesignModeArtifactStore(
            directory: directory,
            liveContextSessionID: "current"
        )
        let releasedURL = try await firstStore.saveScreenshot(
            Data([0]),
            surfaceID: UUID(),
            retention: .liveContext
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: releasedURL.path
        )
        await firstStore.release(releasedURL)

        for value in 0...100 {
            _ = try await secondStore.saveScreenshot(Data([UInt8(value)]), surfaceID: UUID())
        }

        #expect(!FileManager.default.fileExists(atPath: releasedURL.path))
    }

    @Test func saveFailsInsteadOfReturningAnImmediatelyPrunedArtifact() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-save-survival-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDesignModeArtifactStore(directory: directory)

        for value in 0..<100 {
            _ = try await store.saveScreenshot(
                Data([UInt8(value)]),
                surfaceID: UUID(),
                retention: .liveContext
            )
        }

        await #expect(throws: CocoaError.self) {
            _ = try await store.saveContextJSON(Data("{}".utf8), surfaceID: UUID())
        }
    }

    @Test func contextJSONUsesTheScreenshotPruningLifecycle() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-context-pruning-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserDesignModeArtifactStore(directory: directory)
        let surfaceID = UUID()
        let contextURL = try await store.saveContextJSON(Data("{}".utf8), surfaceID: surfaceID)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: contextURL.path
        )

        #expect(contextURL.pathExtension == "json")
        #expect(contextURL.deletingLastPathComponent() == directory)
        for value in 0...100 {
            _ = try await store.saveScreenshot(Data([UInt8(value)]), surfaceID: surfaceID)
        }

        #expect(!FileManager.default.fileExists(atPath: contextURL.path))
    }

    @Test func validationKeepsArtifactReadableThroughConcurrentPruning() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-handoff-race-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let validatingStore = BrowserDesignModeArtifactStore(directory: directory)
        let competingStore = BrowserDesignModeArtifactStore(directory: directory)
        let artifact = try await validatingStore.saveContextJSON(
            Data("{}".utf8),
            surfaceID: UUID()
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: artifact.path
        )
        for value in 0..<99 {
            _ = try await competingStore.saveScreenshot(
                Data([UInt8(value)]),
                surfaceID: UUID()
            )
        }

        let lease = await validatingStore.beginHandoff()
        #expect(await validatingStore.retainHandoffArtifacts(at: [artifact.path], lease: lease))
        _ = try await competingStore.saveScreenshot(Data([255]), surfaceID: UUID())

        #expect(FileManager.default.fileExists(atPath: artifact.path))

        await validatingStore.releaseHandoff(lease)
        _ = try await competingStore.saveScreenshot(Data([254]), surfaceID: UUID())

        #expect(!FileManager.default.fileExists(atPath: artifact.path))
    }

    @Test func liveContextFromAnEarlierAppSessionBecomesPrunable() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-session-pruning-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldStore = BrowserDesignModeArtifactStore(
            directory: directory,
            liveContextSessionID: "old"
        )
        let staleURL = try await oldStore.saveScreenshot(
            Data([0]),
            surfaceID: UUID(),
            retention: .liveContext
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: staleURL.path
        )
        let currentStore = BrowserDesignModeArtifactStore(
            directory: directory,
            liveContextSessionID: "current"
        )

        for value in 0...100 {
            _ = try await currentStore.saveScreenshot(Data([UInt8(value)]), surfaceID: UUID())
        }

        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
    }

    @Test func handoffLeaseFromAnEarlierAppSessionBecomesPrunable() async throws {
        let directory = URL.temporaryDirectory
            .appendingPathComponent("cmux-design-mode-handoff-session-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldStore = BrowserDesignModeArtifactStore(
            directory: directory,
            liveContextSessionID: "old"
        )
        let staleURL = try await oldStore.saveContextJSON(
            Data("{}".utf8),
            surfaceID: UUID()
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: staleURL.path
        )
        let staleLease = await oldStore.beginHandoff()
        #expect(await oldStore.retainHandoffArtifacts(at: [staleURL.path], lease: staleLease))
        let currentStore = BrowserDesignModeArtifactStore(
            directory: directory,
            liveContextSessionID: "current"
        )

        for value in 0...100 {
            _ = try await currentStore.saveScreenshot(Data([UInt8(value)]), surfaceID: UUID())
        }

        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
    }

    private func handoffMarkerNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".handoff-") }
    }
}
