public import CmuxiOSPlatform
public import SwiftUI

/// Settings > What's New: every version visible on this channel.
public struct WhatsNewArchiveView: View {
    let entries: [WhatsNewEntry]

    public init(entries: [WhatsNewEntry]) { self.entries = entries }

    public var body: some View {
        List {
            if entries.isEmpty {
                Text(PlatformText.whatsNewEmpty).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                NavigationLink(PlatformText.version(entry.version.description)) {
                    WhatsNewView(entry: entry)
                }
            }
        }
        .navigationTitle(PlatformText.whatsNewTitle)
    }
}
