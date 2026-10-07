import SwiftUI

/// Open source the app ships, with each project's license.
struct AcknowledgementsView: View {
    private let entries: [Acknowledgement] = [
        Acknowledgement(name: "Ghostty", license: "MIT", url: "https://github.com/ghostty-org/ghostty"),
        Acknowledgement(name: "JetBrains Mono", license: "OFL-1.1", url: "https://github.com/JetBrains/JetBrainsMono"),
        Acknowledgement(name: "SwiftNIO SSH", license: "Apache-2.0", url: "https://github.com/apple/swift-nio-ssh"),
        Acknowledgement(name: "Sentry Cocoa", license: "MIT", url: "https://github.com/getsentry/sentry-cocoa"),
        Acknowledgement(name: "Stack Auth Swift SDK", license: "MIT", url: "https://github.com/stack-auth/stack-auth"),
    ]

    var body: some View {
        List(entries) { entry in
            Link(destination: URL(string: entry.url)!) {
                LabeledContent(entry.name, value: entry.license)
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle(SettingsText.acknowledgements)
    }
}
