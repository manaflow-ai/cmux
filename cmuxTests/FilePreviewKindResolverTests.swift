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

    private func temporaryFile(extension fileExtension: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-preview-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
