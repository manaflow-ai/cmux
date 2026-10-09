public import CmuxiOSPlatform
public import SwiftUI

/// One version's notes: the post-update sheet and the archive's detail.
public struct WhatsNewView: View {
    let entry: WhatsNewEntry
    let onDone: (() -> Void)?

    public init(entry: WhatsNewEntry, onDone: (() -> Void)? = nil) {
        self.entry = entry
        self.onDone = onDone
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(PlatformText.whatsNewTitle).font(.largeTitle.bold())
                    Text(PlatformText.version(entry.version.description))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                ForEach(entry.items) { item in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: item.systemImage)
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if let onDone {
                Button(action: onDone) {
                    Text(PlatformText.continueLabel).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .controlSize(.large)
                .padding(24)
                .accessibilityIdentifier("platform.whatsNew.continue")
            }
        }
    }
}
