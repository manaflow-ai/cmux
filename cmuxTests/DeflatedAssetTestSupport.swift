import Foundation
import zlib

/// Writes and reads `.deflate` fixtures in the format the shipped assets use: zlib-wrapped
/// deflate (RFC 1950), which is what `scripts/compress-markdown-viewer-assets.sh` produces and
/// the only thing `DiffViewerAssetReader`/`MarkdownViewerAssets` can inflate. Foundation's
/// `.zlib` algorithm emits header-less raw deflate (RFC 1951), which those readers reject.
enum DeflatedAssetTestSupport {
    static func writeText(_ text: String, to url: URL, addingDeflateExtension: Bool = false) throws {
        let targetURL = addingDeflateExtension ? url.appendingPathExtension("deflate") : url
        try Self.zlibCompressed(Array(text.utf8)).write(to: targetURL, options: .atomic)
    }

    static func loadText(path: String) throws -> String {
        let compressed = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        guard let text = String(bytes: try Self.zlibDecompressed(compressed), encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }

    private static func zlibCompressed(_ source: [UInt8]) throws -> Data {
        var destinationCount = compressBound(uLong(source.count))
        var destination = [UInt8](repeating: 0, count: Int(destinationCount))
        guard compress2(&destination, &destinationCount, source, uLong(source.count), 9) == Z_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Data(destination[0..<Int(destinationCount)])
    }

    private static func zlibDecompressed(_ compressed: [UInt8]) throws -> [UInt8] {
        var capacity = max(compressed.count * 8, 64 * 1024)
        while capacity <= 64 * 1024 * 1024 {
            var destinationCount = uLong(capacity)
            var destination = [UInt8](repeating: 0, count: capacity)
            let status = uncompress(&destination, &destinationCount, compressed, uLong(compressed.count))
            if status == Z_OK { return Array(destination[0..<Int(destinationCount)]) }
            guard status == Z_BUF_ERROR else { throw CocoaError(.fileReadCorruptFile) }
            capacity *= 4
        }
        throw CocoaError(.fileReadTooLarge)
    }
}
