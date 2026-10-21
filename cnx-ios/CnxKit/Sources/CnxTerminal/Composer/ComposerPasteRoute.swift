import Foundation

/// What the composer's Paste does with the pasteboard (design/terminal R2-2).
/// A copied file is attached like one picked in Files: uploaded to the Mac
/// on send and typed as its path there. A phone `file:///` path means
/// nothing to the Mac's shell, so it is never typed. Portable, unit tested.
public enum ComposerPasteRoute: Equatable, Sendable {
    /// An image: an attachment chip.
    case image
    /// A file on this phone: read and attached (uploaded on send).
    case file(URL)
    /// Plain text: into the field.
    case text(String)
    case nothing

    public static func route(hasImage: Bool, fileURL: URL?, string: String?) -> ComposerPasteRoute {
        if hasImage { return .image }
        if let fileURL, fileURL.isFileURL, fileURL.path.count > 1 { return .file(fileURL) }
        if let string {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("file://") {
                if let url = URL(string: trimmed), url.isFileURL, url.path.count > 1 { return .file(url) }
                return .nothing
            }
            return string.isEmpty ? .nothing : .text(string)
        }
        return .nothing
    }

    /// The attachment menu offers Paste (first) only for an image or a file.
    public static func offersPaste(hasImage: Bool, hasFileURL: Bool) -> Bool {
        hasImage || hasFileURL
    }
}
