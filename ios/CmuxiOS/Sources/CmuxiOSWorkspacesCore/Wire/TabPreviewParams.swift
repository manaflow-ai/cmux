import Foundation

/// `workspace.preview.set` params.
struct TabPreviewParams: Codable, Sendable {
    var tab: String
    var preview: String
}
