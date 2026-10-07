public import CmuxiOSPlatform

/// What's New pages compiled into the app, newest last. Entries without
/// channels show on dev and beta only.
public struct WhatsNewCatalog: Sendable {
    public let entries: [WhatsNewEntry]

    public init() {
        entries = [
            WhatsNewEntry(version: AppVersion("1.0.6")!, items: [
                WhatsNewItem(systemImage: "square.grid.2x2",
                             title: PlatformText.whatsNewShellTitle, detail: PlatformText.whatsNewShellDetail),
                WhatsNewItem(systemImage: "link",
                             title: PlatformText.whatsNewLinksTitle, detail: PlatformText.whatsNewLinksDetail),
                WhatsNewItem(systemImage: "stethoscope",
                             title: PlatformText.whatsNewDiagnosticsTitle, detail: PlatformText.whatsNewDiagnosticsDetail),
            ]),
        ]
    }
}
