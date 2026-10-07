public import SwiftUI

/// A Settings row the composition root adds without the shell knowing the
/// screen behind it (Diagnostics, What's New, Plans, Demo content).
public struct ShellSettingsLink: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let destination: @MainActor () -> AnyView

    public init(id: String, title: String, systemImage: String, destination: @escaping @MainActor () -> AnyView) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.destination = destination
    }
}
