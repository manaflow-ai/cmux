public import CmuxiOSFeatureKit
import Foundation

/// A file the user attached to a draft. Bytes go to the Mac through C4; the
/// draft keeps only this reference and, once uploaded, the Mac's upload id.
public struct ComposerAttachment: Identifiable, Hashable, Sendable, Codable {
    public enum Phase: String, Hashable, Sendable, Codable {
        case uploading
        case ready
        case failed
    }

    public var id: TransferID
    public var name: String
    public var mime: String
    public var byteCount: Int64
    /// `up_…` from `files.upload` (`channel.opened.upload`); nil until known.
    public var uploadID: String?
    public var phase: Phase

    public init(id: TransferID, name: String, mime: String, byteCount: Int64, uploadID: String? = nil,
                phase: Phase = .uploading) {
        self.id = id
        self.name = name
        self.mime = mime
        self.byteCount = byteCount
        self.uploadID = uploadID
        self.phase = phase
    }

    public var isImage: Bool { mime.hasPrefix("image/") }
}
