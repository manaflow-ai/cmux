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
                FilePreviewKindResolver.initialMode(for: url) == .text,
                "Expected .\(fileExtension) to avoid the QuickLook/media backend before async resolution."
            )
            #expect(FilePreviewKindResolver.mode(for: url) == .text)
        }
    }

    @Test("Source files stay text when a multi-byte character straddles the sniff window")
    func sourceFilesStayTextWhenMultiByteCharacterStraddlesSniffWindow() throws {
        let url = try temporaryFile(
            extension: "ts",
            data: multiByteCharacterAtSniffBoundary(
                prefix: "// ",
                suffix: "\nexport const value: number = 42;\n"
            )
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            FilePreviewKindResolver.mode(for: url) == .text,
            "A TypeScript file must not fall back to the media player because the 4 KB read cut a scalar in half."
        )
    }

    @Test("Unknown extensions stay text when a multi-byte character straddles the sniff window")
    func unknownExtensionsStayTextWhenMultiByteCharacterStraddlesSniffWindow() throws {
        let url = try temporaryFile(
            extension: "typ",
            data: multiByteCharacterAtSniffBoundary(
                prefix: "= ",
                suffix: "\nÜberschrift\n"
            )
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FilePreviewKindResolver.mode(for: url) == .text)
    }

    @Test("Single-byte encoded text resolves to the text editor")
    func singleByteEncodedTextResolvesToTextEditor() throws {
        let data = try #require("Straße;Grüße;Übung\n".data(using: .isoLatin1))
        let url = try temporaryFile(extension: "dat", data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            FilePreviewKindResolver.mode(for: url) == .text,
            "FilePreviewTextLoader decodes ISO Latin-1, so the resolver has to route the same files to the editor."
        )
    }

    @Test("Binary payloads without NUL bytes keep the QuickLook backend")
    func binaryPayloadsWithoutNulBytesKeepQuickLookBackend() throws {
        var data = Data()
        for index in 0..<4096 {
            data.append(index.isMultiple(of: 2) ? 0xFE : 0x07)
        }
        let url = try temporaryFile(extension: "bin", data: data)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FilePreviewKindResolver.mode(for: url) == .quickLook)
    }

    @Test("A file shorter than the read window keeps its malformed tail")
    func aFileShorterThanTheReadWindowKeepsItsMalformedTail() throws {
        let url = try temporaryFile(extension: "bin", data: Data([0x07, 0xC3]))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            FilePreviewKindResolver.mode(for: url) == .quickLook,
            "The read never truncated this file, so the lone lead byte is a defect and the control byte decides."
        )
    }

    @Test("A prefix ending in an invalid lead byte is not treated as truncated")
    func aPrefixEndingInAnInvalidLeadByteIsNotTreatedAsTruncated() throws {
        var payload = Data(repeating: 0x61, count: FilePreviewKindResolver.sniffPrefixByteCount - 2)
        payload.append(0x07)
        payload.append(0xC0)  // overlong lead, never starts a valid sequence
        let url = try temporaryFile(extension: "bin", data: payload)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            FilePreviewKindResolver.mode(for: url) == .quickLook,
            "Dropping 0xC0 as a cut scalar would hide the control byte behind a clean UTF-8 decode."
        )
    }

    @Test("A file that ends exactly at the read window keeps its malformed tail")
    func aFileThatEndsExactlyAtTheReadWindowKeepsItsMalformedTail() throws {
        var payload = Data(repeating: 0x61, count: FilePreviewKindResolver.sniffPrefixByteCount - 2)
        payload.append(0x07)
        payload.append(0xC3)
        let url = try temporaryFile(extension: "bin", data: payload)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(payload.count == FilePreviewKindResolver.sniffPrefixByteCount)
        #expect(
            FilePreviewKindResolver.mode(for: url) == .quickLook,
            "Nothing follows this prefix, so the lone lead byte is a defect and the control byte decides."
        )
    }

    @Test("A tail that violates its lead-specific range is not treated as truncated")
    func aTailThatViolatesItsLeadSpecificRangeIsNotTreatedAsTruncated() throws {
        var payload = Data(repeating: 0x61, count: FilePreviewKindResolver.sniffPrefixByteCount - 3)
        payload.append(0x07)
        payload.append(0xE0)
        payload.append(0x80)  // 0xE0 admits 0xA0...0xBF only; this is an overlong form
        payload.append(contentsOf: Data(repeating: 0x61, count: 16))
        let url = try temporaryFile(extension: "bin", data: payload)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            FilePreviewKindResolver.mode(for: url) == .quickLook,
            "Dropping a sequence that was never valid would hide the control byte behind a clean UTF-8 decode."
        )
    }

    @Test("Valid UTF-8 carrying a control byte still resolves to text")
    func validUTF8CarryingAControlByteStillResolvesToText() throws {
        let url = try temporaryFile(extension: "dat", contents: "ring \u{07} and continue\n")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            FilePreviewKindResolver.mode(for: url) == .text,
            "Bundled JavaScript and terminal captures carry C0 bytes; a valid UTF-8 decode still means text."
        )
    }

    /// UTF-8 whose sniff prefix ends on the lead byte of a two-byte scalar,
    /// which is what the fixed-size sniff read cuts in half.
    private func multiByteCharacterAtSniffBoundary(prefix: String, suffix: String) -> Data {
        let padding = String(
            repeating: "a",
            count: FilePreviewKindResolver.sniffPrefixByteCount - prefix.utf8.count - 1
        )
        return Data((prefix + padding + "ä" + suffix).utf8)
    }

    @Test("Movie file extensions keep media preview")
    func movieFileExtensionsKeepMediaPreview() throws {
        for fileExtension in ["mov", "mp4"] {
            let url = try temporaryFile(
                extension: fileExtension,
                contents: "not a source file\n"
            )
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(FilePreviewKindResolver.initialMode(for: url) == .media)
            #expect(FilePreviewKindResolver.mode(for: url) == .media)
        }
    }

    @Test("MTS binary transport streams keep media preview after sniffing")
    func mtsBinaryTransportStreamsKeepMediaPreviewAfterSniffing() throws {
        let url = try temporaryFile(
            extension: "mts",
            data: mpegTransportStreamData(packetSize: 192, syncOffset: 4)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FilePreviewKindResolver.initialMode(for: url) == .text)
        #expect(FilePreviewKindResolver.mode(for: url) == .media)
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
        try handle.truncate(atOffset: FilePreviewTextLoader.maximumLoadedTextBytes + 1)
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
