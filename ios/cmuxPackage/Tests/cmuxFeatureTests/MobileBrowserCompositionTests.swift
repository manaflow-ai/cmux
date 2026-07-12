import CmuxMobileBrowser
import Foundation
import Testing
@testable import CmuxMobileShellUI
@testable import cmuxFeature

@MainActor
@Test func browserCompositionSharesOneArchiveAcrossSceneConsumers() async throws {
    let suiteName = "MobileBrowserCompositionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let composition = MobileBrowserComposition(defaults: defaults)
    let firstScene = CMUXMobileAppView(
        store: .preview(),
        browserStore: composition.store,
        onboardingStore: MobileOnboardingStore(defaults: defaults, forceSeen: true)
    )
    let secondScene = CMUXMobileAppView(
        store: .preview(),
        browserStore: composition.store,
        onboardingStore: MobileOnboardingStore(defaults: defaults, forceSeen: true)
    )

    #expect(firstScene.browserStore === composition.store)
    #expect(secondScene.browserStore === composition.store)

    let scope = BrowserPersistenceScope(userID: "user", teamID: "team")
    firstScene.browserStore.setPersistenceScope(scope)
    _ = firstScene.browserStore.openBrowser(for: "workspace-a")
    _ = secondScene.browserStore.openBrowser(for: "workspace-b")
    await composition.store.flushPersistence()

    let restored = BrowserSurfaceStore(defaultURL: nil, persistenceDefaults: defaults)
    restored.setPersistenceScope(scope)
    #expect(restored.browser(for: "workspace-a") != nil)
    #expect(restored.browser(for: "workspace-b") != nil)
}
