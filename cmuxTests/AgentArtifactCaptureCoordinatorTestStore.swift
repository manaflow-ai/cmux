import CmuxArtifacts
import Foundation

actor OutOfOrderCaptureStore: ArtifactStoring {
    private let suspendsFirstImport: Bool
    private let rejectsFirstImportAsBusy: Bool
    private let captureConfiguration: ArtifactCaptureConfiguration
    private var firstImportStarted: CheckedContinuation<Void, Never>?
    private var firstImportRelease: CheckedContinuation<Void, Never>?
    private(set) var importCount = 0
    private(set) var importedPaths: [String] = []

    init(
        suspendsFirstImport: Bool = true,
        rejectsFirstImportAsBusy: Bool = false,
        maximumFilesPerCapture: Int = ArtifactCaptureConfiguration.defaultValue.maximumFilesPerCapture
    ) {
        self.suspendsFirstImport = suspendsFirstImport
        self.rejectsFirstImportAsBusy = rejectsFirstImportAsBusy
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.maximumFilesPerCapture = maximumFilesPerCapture
        captureConfiguration = configuration
    }

    func waitUntilFirstImportStarts() async {
        guard importCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstImportStarted = continuation
        }
    }

    func releaseFirstImport() {
        firstImportRelease?.resume()
        firstImportRelease = nil
    }

    func locateProjectRoot(startingAt url: URL) -> URL {
        url
    }

    func configuration(projectRoot _: URL) -> ArtifactCaptureConfiguration {
        captureConfiguration
    }

    func snapshot(projectRoot: URL) throws -> ArtifactSnapshot {
        ArtifactSnapshot(
            projectRoot: projectRoot,
            filesystemRoot: projectRoot.appendingPathComponent(".cmux"),
            nodes: [],
            isTruncated: false
        )
    }

    func search(projectRoot _: URL, query _: String) -> [ArtifactSearchResult] {
        []
    }

    func importFile(
        sourceURL _: URL,
        context _: ArtifactCaptureContext,
        provenance _: ArtifactProvenance,
        configuration _: ArtifactCaptureConfiguration,
        capturedAt _: Date
    ) throws -> ArtifactImportOutcome {
        .skipped(.notARegularFile)
    }

    func importFiles(
        candidates: [ArtifactCandidate],
        context _: ArtifactCaptureContext,
        configuration _: ArtifactCaptureConfiguration,
        capturedAt _: Date
    ) async -> [ArtifactImportAttempt] {
        importCount += 1
        if importCount == 1, rejectsFirstImportAsBusy {
            return candidates.map { _ in
                .rejected(.storeBusy("artifact store"))
            }
        }
        importedPaths.append(contentsOf: candidates.map(\.sourceURL.path))
        if importCount == 1, suspendsFirstImport {
            firstImportStarted?.resume()
            firstImportStarted = nil
            await withCheckedContinuation { continuation in
                firstImportRelease = continuation
            }
        }
        return candidates.map { _ in
            .imported(.skipped(.notARegularFile))
        }
    }

    func resolve(projectRoot _: URL, name: String) throws -> ArtifactNode {
        throw ArtifactStoreError.artifactNotFound(name)
    }

    func changes(projectRoot _: URL) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
