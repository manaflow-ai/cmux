public import Foundation

/// A file staged on the phone for upload into the Mac's inbox.
public struct ComposerUploadFile: Hashable, Sendable {
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

    public var isImage: Bool { mime.hasPrefix("image/") }
}
