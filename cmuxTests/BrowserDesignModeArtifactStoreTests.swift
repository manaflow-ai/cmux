import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserDesignModeArtifactStoreTests {
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
}
