import Foundation
import UniformTypeIdentifiers

/// Copies picked items into `tmp/cmux-transfers/<id>/` so an upload reads a
/// file the app owns (picker URLs are temporary or security scoped), and
/// converts HEIC to JPEG when asked.
public struct FileStager: Sendable {
    public let root: URL
    public var transcoder: ImageTranscoder

    public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-transfers", isDirectory: true),
                transcoder: ImageTranscoder = ImageTranscoder()) {
        self.root = root
        self.transcoder = transcoder
    }

    /// Copies `source` (reading it under its security scope when it has one).
    public func stage(copying source: URL, name: String? = nil, convertHEIC: Bool) throws -> StagedFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let directory = try makeDirectory()
        var target = directory.appendingPathComponent(Self.cleanName(name ?? source.lastPathComponent))
        try FileManager.default.copyItem(at: source, to: target)
        if convertHEIC, ImageTranscoder.isHEIC(target), let jpeg = try? transcoder.jpeg(from: target) {
            try? FileManager.default.removeItem(at: target)
            target = jpeg
        }
        return try describe(target)
    }

    /// Writes bytes (a camera capture) as `name`.
    public func stage(data: Data, name: String) throws -> StagedFile {
        let target = try makeDirectory().appendingPathComponent(Self.cleanName(name))
        try data.write(to: target, options: .atomic)
        return try describe(target)
    }

    /// Removes a staged file's directory after its upload finished or was cancelled.
    public func discard(_ file: StagedFile) {
        let directory = file.url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDirectory() throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func describe(_ url: URL) throws -> StagedFile {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return StagedFile(url: url, name: url.lastPathComponent, mime: Self.mime(for: url), byteCount: size)
    }

    static func mime(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func cleanName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }
}
