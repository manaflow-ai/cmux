import AppKit
import CmuxSettings
import CmuxUpdater
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("What's New launch mode", .serialized)
struct WhatsNewCenterLaunchModeTests {
    @Test(arguments: [WhatsNewPresentationMode.sheet, .quiet])
    func switchingOffDuringCatalogLoadSuppressesTheAnnouncement(startingMode: WhatsNewPresentationMode) async throws {
        let suite = "WhatsNewCenterLaunchModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("0.64.24", forKey: WhatsNewCenter.lastSeenReleaseDefaultsKey)
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        settings.set(startingMode, for: AppCatalogSection().whatsNew)

        let catalog = WhatsNewCatalog(releases: [
            WhatsNewRelease(version: "0.64.25", title: "cmux 0.64.25", features: [
                WhatsNewRelease.Feature(title: "Highlight", description: "Available now")
            ])
        ])
        let loader = BlockedCatalogLoader(catalog: catalog)
        let center = WhatsNewCenter(
            defaults: defaults,
            loader: { await loader.load() },
            buildFlavor: .stable,
            currentVersion: "0.64.25"
        )

        center.startupSessionRestoreDidSettle()
        await loader.waitUntilStarted()
        settings.set(.off, for: AppCatalogSection().whatsNew)
        await loader.release()
        await center.waitForLaunchCheck()

        #expect(!center.hasUnseenHighlights)
        #expect(!NSApp.windows.contains { $0.identifier?.rawValue == "cmux.whatsNew" })
    }
}

private actor BlockedCatalogLoader {
    let catalog: WhatsNewCatalog
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(catalog: WhatsNewCatalog) { self.catalog = catalog }

    func load() async -> WhatsNewCatalog {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return catalog
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
