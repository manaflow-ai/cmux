public import Foundation

/// The real file wipe over `FileManager`.
public struct FileManagerWiper: FileWiping {
    public init() {}

    public func children(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
