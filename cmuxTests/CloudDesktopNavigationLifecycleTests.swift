import CmuxCloud
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Desktop navigation ownership", .serialized, .timeLimit(.minutes(1)))
struct CloudDesktopNavigationLifecycleTests {
    @Test("Sidebar click, menu and drop open a Desktop without a SwiftUI host",
          arguments: [false, true], CloudDesktopNavigationFixture.EntryPoint.allCases)
    func opensWithoutMountedView(cached: Bool, entryPoint: CloudDesktopNavigationFixture.EntryPoint) async throws {
        try await withFixture { fixture in
            if cached {
                fixture.releaseRoute()
                fixture.model.connect()
                try #require(await AppKitTestEventPump().waitUntil { fixture.model.isReady })
            }
            let browser = try await fixture.open(entryPoint)
            #expect(browser.cloudAccess.isDesktop)
            #expect(browser.cloudAccess.resourceID == fixture.app.display.id)
            #expect(browser.cloudAccess.model === fixture.model)
            if !cached {
                #expect(fixture.documentRequests == 0)
                fixture.releaseRoute()
            }
            try #require(await fixture.waitForDocument(browser),
                "Route readiness must cause a real HTTP/WebSocket load without a view task or manual nextURL call")
            #expect(fixture.documentRequests == 1)
            #expect(browser.webView.url == browser.cloudAccess.remoteURL)
            #expect(browser.cloudAccess.showsPage)
            #expect(browser.webView.configuration.websiteDataStore.proxyConfigurations.count == 1)
            #expect(!fixture.server.bridgeRequests.isEmpty)
            #expect(fixture.app.owner.cloudVMID == fixture.provider.machineID)
        }
    }

    @Test("Stop during route acquisition prevents a delayed load until an explicit retry")
    func stopBeforeReadiness() async throws {
        try await withFixture { fixture in
            let browser = try await fixture.open()
            browser.stopLoading()
            fixture.releaseRoute()
            try #require(await AppKitTestEventPump().waitUntil { fixture.model.isReady })
            await AppKitTestEventPump().drain()
            #expect(browser.cloudAccess.failureMessage != nil)
            #expect(browser.cloudAccess.navigationURL == nil)
            #expect(fixture.documentRequests == 0)
            _ = browser.reload()
            try #require(await fixture.waitForDocument(browser))
            #expect(fixture.documentRequests == 1)
        }
    }

    @Test("A duplicated Desktop and a profile replacement retain automatic navigation")
    func duplicationAndProfileSwitch() async throws {
        try await withFixture { fixture in
            fixture.releaseRoute()
            let first = try await fixture.open()
            try #require(await fixture.waitForDocument(first))
            let second = try #require(fixture.app.owner.duplicateBrowserToRight(panelId: first.id, focus: false))
            try #require(await fixture.waitForDocument(second))
            #expect(fixture.documentRequests == 2)
            #expect(second.cloudAccess.resourceID == fixture.app.display.id)
            #expect(fixture.app.owner.focusedPanelId == first.id)
            let profiles = BrowserProfileStore.shared
            let profile = try #require(profiles.createProfile(named: "Desktop fixture \(UUID())"))
            defer { _ = profiles.deleteProfile(id: profile.id) }
            #expect(second.switchToProfile(profile.id))
            try #require(await AppKitTestEventPump().waitUntil(timeout: .seconds(8)) {
                fixture.documentRequests == 3 && second.cloudAccess.desktopConnected
            })
            #expect(second.cloudAccess.resourceID == fixture.app.display.id)
            #expect(second.webView.configuration.websiteDataStore.proxyConfigurations.count == 1)
        }
    }

    @Test("Retry and a fresh projection do not depend on a SwiftUI task noticing a cached route")
    func retryAndAdditionalProjection() async throws {
        try await withFixture { fixture in
            fixture.releaseRoute()
            let first = try await fixture.open()
            try #require(await fixture.waitForDocument(first))
            _ = first.reload()
            try #require(await AppKitTestEventPump().waitUntil(timeout: .seconds(8)) {
                fixture.documentRequests == 2 && first.cloudAccess.desktopConnected
            })
            let projection = try await fixture.app.catalog.project(
                fixture.app.display.id,
                into: .workspace(id: fixture.app.owner.id, placement: .split),
                focus: false, reuseExisting: false
            ).projection
            let second = try #require(SurfacePaneFactory.browserPanel(
                panelID: projection.panelID, in: projection.workspaceID
            ))
            try #require(await fixture.waitForDocument(second))
            #expect(fixture.documentRequests == 3)
            #expect(first.id != second.id)
            #expect(first.cloudAccess.model === second.cloudAccess.model)
            #expect(second.cloudAccess.resourceID == first.cloudAccess.resourceID)
            #expect(fixture.app.owner.focusedPanelId == first.id)
        }
    }

    @Test("A closed Desktop cannot navigate when its delayed route completes")
    func closeBeforeReadiness() async throws {
        try await withFixture { fixture in
            let browser = try await fixture.open()
            browser.close()
            fixture.releaseRoute()
            try #require(await AppKitTestEventPump().waitUntil { fixture.model.isReady })
            #expect(browser.cloudAccess.model == nil)
            #expect(browser.cloudAccess.navigationURL == nil)
            #expect(fixture.documentRequests == 0)
        }
    }

    @Test("Leaving and re-entering Cloud reattaches navigation to the authorized provider")
    func leaveAndReenter() async throws {
        try await withFixture { fixture in
            fixture.releaseRoute()
            let browser = try await fixture.open()
            try #require(await fixture.waitForDocument(browser))
            let remote = try #require(browser.cloudAccess.remoteURL)
            _ = browser.navigate(to: SurfacePaneFactory.blankURL)
            #expect(browser.cloudAccess.model == nil)
            #expect(fixture.provider.configureBrowser(browser, url: remote,
                resourceID: fixture.app.display.id))
            try #require(await AppKitTestEventPump().waitUntil(timeout: .seconds(8)) {
                fixture.documentRequests == 2 && browser.cloudAccess.desktopConnected
            })
            #expect(browser.cloudAccess.resourceID == fixture.app.display.id)
        }
    }

    @Test("A foreign workspace cannot start the real Desktop provider's transport",
          arguments: ["desktop-a", "desktop-b"])
    func rejectsForeignMachine(machineID: String) async throws {
        try await withFixture(machineID: machineID) { fixture in
            fixture.app.selectedID = fixture.app.other.id
            let before = fixture.app.other.bonsplitController.treeSnapshot()
            try fixture.app.activate(try fixture.app.poolNode())
            await fixture.app.waitForOpen()
            #expect(fixture.app.failures == [SurfaceTransferRejection.cloudMachineMismatch.message])
            #expect(fixture.app.catalog.projections.isEmpty)
            #expect(fixture.app.other.bonsplitController.treeSnapshot() == before)
            #expect(fixture.model.phase == .needsVPN)
            #expect(fixture.server.authorizedTargets.isEmpty)
        }
    }

    private func withFixture(
        machineID: String = "desktop-navigation-\(UUID().uuidString)",
        _ body: @MainActor (CloudDesktopNavigationFixture) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudDesktopNavigationFixture(machineID: machineID)
            do {
                try await fixture.start()
                try await body(fixture)
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
    }
}
