import Foundation
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileBrowser
@testable import CmuxMobileShellUI
@testable import cmuxFeature

@MainActor
@Test func browserCompositionSharesPersistenceWithoutSharingLiveSceneState() async throws {
    let suiteName = "MobileBrowserCompositionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let composition = MobileBrowserComposition(defaults: defaults)
    let firstStore = composition.makeSceneStore()
    let secondStore = composition.makeSceneStore()
    let firstScene = CMUXMobileAppView(
        store: .preview(),
        browserStore: firstStore,
        onboardingStore: MobileOnboardingStore(defaults: defaults, forceSeen: true)
    )
    let secondScene = CMUXMobileAppView(
        store: .preview(),
        browserStore: secondStore,
        onboardingStore: MobileOnboardingStore(defaults: defaults, forceSeen: true)
    )

    #expect(firstScene.browserStore === firstStore)
    #expect(secondScene.browserStore === secondStore)
    #expect(firstScene.browserStore !== secondScene.browserStore)

    let scope = BrowserPersistenceScope(userID: "user", teamID: "team")
    firstScene.browserStore.setPersistenceScope(scope)
    secondScene.browserStore.setPersistenceScope(scope)
    let firstShared = firstScene.browserStore.openBrowser(for: "workspace-shared")
    firstShared.navigationDidFinish(
        url: URL(string: "https://first.example")!,
        title: "First"
    )
    _ = firstScene.browserStore.openBrowser(for: "workspace-first-only")
    let secondShared = secondScene.browserStore.openBrowser(for: "workspace-shared")
    secondShared.navigationDidFinish(
        url: URL(string: "https://second.example")!,
        title: "Second"
    )
    let secondOnly = secondScene.browserStore.openBrowser(for: "workspace-second-only")

    firstScene.browserStore.showNonBrowserSurface(for: "workspace-shared")
    firstShared.request(.reload)
    #expect(firstScene.browserStore.activeBrowser(for: "workspace-shared") == nil)
    #expect(secondScene.browserStore.activeBrowser(for: "workspace-shared") === secondShared)
    #expect(secondShared.pendingCommand == nil)

    firstScene.browserStore.closeBrowser(for: "workspace-shared")
    firstScene.browserStore.reconcileWorkspaces([] as [String])

    #expect(secondScene.browserStore.browser(for: "workspace-shared") === secondShared)
    #expect(secondScene.browserStore.browser(for: "workspace-second-only") === secondOnly)
    #expect(secondShared.currentURL?.absoluteString == "https://second.example")
    await composition.flushPersistence()

    let restored = composition.makeSceneStore(defaultURL: nil)
    restored.setPersistenceScope(scope)
    #expect(restored.browser(for: "workspace-first-only") == nil)
    #expect(restored.browser(for: "workspace-shared")?.currentURL?.absoluteString == "https://second.example")
    #expect(restored.browser(for: "workspace-second-only") != nil)
}

@MainActor
@Test func closedSceneCannotRepublishADeletedBrowser() async throws {
    let suiteName = "MobileBrowserCompositionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let composition = MobileBrowserComposition(defaults: defaults)
    let scope = BrowserPersistenceScope(userID: "user", teamID: "team")
    var departingStore: BrowserSurfaceStore? = composition.makeSceneStore(defaultURL: nil)
    departingStore?.setPersistenceScope(scope)
    _ = departingStore?.openBrowser(for: "workspace")

    let activeStore = composition.makeSceneStore(defaultURL: nil)
    activeStore.setPersistenceScope(scope)
    #expect(activeStore.browser(for: "workspace") != nil)
    weak var releasedStore = departingStore
    departingStore = nil
    #expect(releasedStore == nil)

    activeStore.closeBrowser(for: "workspace")
    await composition.flushPersistence()

    let observer = composition.makeSceneStore(defaultURL: nil)
    observer.setPersistenceScope(scope)
    #expect(observer.browser(for: "workspace") == nil)
}
