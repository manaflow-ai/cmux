import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("File preview kind resolver")
struct FilePreviewKindResolverTests {
    @Test("TypeScript-family source files route directly to text preview")
    func typeScriptFamilySourceFilesRouteDirectlyToTextPreview() throws {
        for fileExtension in ["ts", "tsx", "cts", "mts"] {
            let url = try temporaryFile(
                extension: fileExtension,
                contents: "export const value: number = 42;\n"
            )
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(
                FilePreviewKindResolver().initialMode(for: url) == .text,
                "Expected .\(fileExtension) to avoid the QuickLook/media backend before async resolution."
            )
            #expect(FilePreviewKindResolver().mode(for: url) == .text)
        }
    }

    @Test("Movie file extensions keep media preview")
    func movieFileExtensionsKeepMediaPreview() throws {
        for fileExtension in ["mov", "mp4"] {
            let url = try temporaryFile(
                extension: fileExtension,
                contents: "not a source file\n"
            )
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(FilePreviewKindResolver().initialMode(for: url) == .media)
            #expect(FilePreviewKindResolver().mode(for: url) == .media)
        }
    }

    @Test("MTS binary transport streams keep media preview after sniffing")
    func mtsBinaryTransportStreamsKeepMediaPreviewAfterSniffing() throws {
        let url = try temporaryFile(
            extension: "mts",
            data: mpegTransportStreamData(packetSize: 192, syncOffset: 4)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FilePreviewKindResolver().initialMode(for: url) == .text)
        #expect(FilePreviewKindResolver().mode(for: url) == .media)
    }

    @MainActor
    @Test("Media previews ignore stale text-load completions")
    func mediaPreviewsIgnoreStaleTextLoadCompletions() async throws {
        let url = try temporaryOversizedMPEGTransportStream(
            extension: "mts",
            packetSize: 192,
            syncOffset: 4
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = DeferredTextLoader(result: .unavailable)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: url.path,
            textLoader: { url in await loader.load(url: url) }
        )
        defer { panel.close() }

        #expect(panel.previewMode == .text)
        await loader.waitUntilStarted()
        let resolvedAsMedia = await waitForPreviewMode(panel, .media)
        #expect(resolvedAsMedia)
        #expect(panel.isFileUnavailable == false)

        await loader.release()
        await loader.waitUntilCompleted()

        #expect(panel.previewMode == .media)
        #expect(panel.isFileUnavailable == false)
        #expect(panel.textContent.isEmpty)
    }

    private func temporaryFile(extension fileExtension: String, contents: String) throws -> URL {
        try temporaryFile(extension: fileExtension, data: Data(contents.utf8))
    }

    private func temporaryFile(extension fileExtension: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-preview-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func temporaryOversizedMPEGTransportStream(
        extension fileExtension: String,
        packetSize: Int,
        syncOffset: Int
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-preview-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: mpegTransportStreamData(packetSize: packetSize, syncOffset: syncOffset))
        try handle.truncate(atOffset: FilePreviewTextLoader().maximumLoadedTextBytes + 1)
        return url
    }

    private func mpegTransportStreamData(packetSize: Int, syncOffset: Int) -> Data {
        var data = Data(repeating: 0, count: syncOffset + packetSize * 2)
        data[syncOffset] = 0x47
        data[syncOffset + 1] = 0x40
        data[syncOffset + 2] = 0x00
        data[syncOffset + 3] = 0x10
        data[syncOffset + packetSize] = 0x47
        data[syncOffset + packetSize + 1] = 0x41
        data[syncOffset + packetSize + 2] = 0x00
        data[syncOffset + packetSize + 3] = 0x10
        return data
    }

    @MainActor
    private func waitForPreviewMode(_ panel: FilePreviewPanel, _ mode: FilePreviewMode) async -> Bool {
        for _ in 0..<1000 {
            if panel.previewMode == mode {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

private actor DeferredTextLoader {
    private let result: FilePreviewTextLoader.Result
    private var didStart = false
    private var didComplete = false
    private var isReleased = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var completionContinuations: [CheckedContinuation<Void, Never>] = []

    init(result: FilePreviewTextLoader.Result) {
        self.result = result
    }

    func load(url: URL) async -> FilePreviewTextLoader.Result {
        _ = url
        didStart = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }

        didComplete = true
        completionContinuations.forEach { $0.resume() }
        completionContinuations.removeAll()
        return result
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseContinuations.forEach { $0.resume() }
        releaseContinuations.removeAll()
    }

    func waitUntilCompleted() async {
        guard !didComplete else { return }
        await withCheckedContinuation { continuation in
            completionContinuations.append(continuation)
        }
    }
}
