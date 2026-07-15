import Foundation

enum DeflatedAssetTestSupport {
    static func writeText(_ text: String, to url: URL, addingDeflateExtension: Bool = false) throws {
        let targetURL = addingDeflateExtension ? url.appendingPathExtension("deflate") : url
        let compressed = try (Data(text.utf8) as NSData).compressed(using: .zlib) as Data
        try compressed.write(to: targetURL, options: .atomic)
    }

    static func loadText(path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decompressed = try (data as NSData).decompressed(using: .zlib) as Data
        guard let text = String(bytes: decompressed, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }
}
