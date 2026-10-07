import Foundation


/// A new file or folder name typed in the browser: trimmed, not empty, not
/// `.` or `..`, no `/` or control characters, at most 255 UTF-8 bytes
/// (the common file-system limit).
public struct ViewerFileName: Hashable, Sendable {
    public let value: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"),
              trimmed.utf8.count <= 255,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        value = trimmed
    }
}
