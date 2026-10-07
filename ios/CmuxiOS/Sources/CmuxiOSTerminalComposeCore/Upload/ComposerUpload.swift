public import Foundation

/// One attachment on its way to the Mac, shown as a chip until its path
/// lands in the draft.
public struct ComposerUpload: Identifiable, Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case uploading
        /// Failed or cancelled; the transfer list can still resume it.
        case failed
    }

    public let id: UUID
    public var name: String
    public var isImage: Bool
    public var phase: Phase

    public init(id: UUID = UUID(), name: String, isImage: Bool, phase: Phase = .uploading) {
        self.id = id
        self.name = name
        self.isImage = isImage
        self.phase = phase
    }
}
