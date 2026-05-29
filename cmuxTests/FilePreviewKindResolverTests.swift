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
}
