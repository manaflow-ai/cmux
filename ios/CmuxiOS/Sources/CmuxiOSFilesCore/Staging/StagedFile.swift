import Foundation

/// A picked file copied into the app's transfer staging, ready to upload.
public struct StagedFile: Hashable, Sendable {
    public var url: URL
    public var name: String
    public var mime: String
    public var byteCount: Int64

    public init(url: URL, name: String, mime: String, byteCount: Int64) {
        self.url = url
        self.name = name
        self.mime = mime
        self.byteCount = byteCount
    }
}
