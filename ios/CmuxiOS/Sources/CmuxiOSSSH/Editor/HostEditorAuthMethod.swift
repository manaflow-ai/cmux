import Foundation

/// The login method picked in the editor.
enum HostEditorAuthMethod: String, CaseIterable, Hashable, Sendable {
    case key
    case password
}
