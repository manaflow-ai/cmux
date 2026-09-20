import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudGuestURLRoutingTests {
    @Test func subscriptionMembershipRevisionIgnoresMetadataAndOtherMachines() async throws {
        let catalog = SurfaceCatalog()
        let machine = SurfaceMachineID.cloud("vm-url-fixture")
        let provider = try CloudCatalogQueryTestProvider(machine: machine, catalog: catalog)
        catalog.register(provider)
        await provider.refresh()
        let projection = SurfaceProjection(resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term-seeded"),
                                           workspaceID: UUID(), panelID: UUID())
        catalog.record(projection)
        let revision = catalog.projectionVersions[machine]
        let terminals = catalog.projectedTerminalIDs(on: machine)
        #expect(terminals == ["term-seeded"])
        var resources = catalog.snapshot.resources
        var info = provider.info
        for index in 0..<100 {
            resources[0].title = "title-\(index)"
            info.cpuPercent = Double(index)
            catalog.replaceResources(resources, on: machine)
            catalog.updateMachine(info)
        }
        catalog.record(SurfaceProjection(resource: SurfaceResourceID(machine: .cloud("other"), kind: .terminal, key: "term-other"),
                                         workspaceID: UUID(), panelID: UUID()))
        #expect(catalog.projectionVersions[machine] == revision)
        catalog.endProjections(panelID: projection.panelID, reason: .replaced)
        #expect(catalog.projectedTerminalIDs(on: machine).isEmpty)
        #expect(catalog.projectionVersions[machine] != revision)
    }

    @Test func opensInBackgroundWorkspaceWithoutChangingSelectionOrTerminalFocus() throws {
        _ = NSApplication.shared
        let manager = TabManager()
        defer { for workspace in manager.tabs { workspace.teardownAllPanels() } }
        let selected = try #require(manager.selectedWorkspace)
        let owner = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
        let panel = try #require(owner.focusedPanelId)
        let selectedPanel = selected.focusedPanelId
        let sourcePane = owner.bonsplitController.focusedPaneId
        let suite = "guest-url-background-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        let coordinator = TerminalLinkOpenCoordinator(defaults: defaults, containerResolver: { workspace, surface in
            workspace == owner.id && surface == panel ? owner : nil
        }, externalOpen: { _ in Issue.record("Expected a browser in the owning workspace"); return false })
        #expect(coordinator.open(TerminalLinkOpenRequest(rawValue: "https://example.invalid/device", sourceWorkspaceId: owner.id,
                                                        sourcePanelId: panel, workingDirectory: nil, focus: false)))
        #expect(owner.panels.values.contains { $0 is BrowserPanel })
        #expect(!selected.panels.values.contains { $0 is BrowserPanel })
        #expect(manager.selectedTabId == selected.id)
        #expect(selected.focusedPanelId == selectedPanel)
        #expect(owner.focusedPanelId == panel)
        #expect(owner.bonsplitController.focusedPaneId == sourcePane)
    }

    @Test func guestOpenerUsesTerminalPolicyAndPreservesFocus() throws {
        let suite = "guest-url-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        let workspace = UUID()
        let panel = UUID()
        let container = CloudGuestURLTestContainer()
        var external: [URL] = []
        let coordinator = TerminalLinkOpenCoordinator(defaults: defaults, containerResolver: { workspaceID, panelID in
            #expect(workspaceID == workspace)
            #expect(panelID == panel)
            return container
        }, externalOpen: { external.append($0); return true }, deferOperation: { _ in
            Issue.record("A guest opener must report real synchronous pane creation, not a deferred success")
        })
        let url = "https://github.com/login/device?state=AbC%2f"
        let request = TerminalLinkOpenRequest(rawValue: url, sourceWorkspaceId: workspace, sourcePanelId: panel,
                                             workingDirectory: nil, focus: false)
        #expect(coordinator.open(request))
        #expect(container.opened == [URL(string: url)!])
        #expect(container.focus == false)
        #expect(external.isEmpty)
        defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        #expect(coordinator.open(request))
        #expect(external == [URL(string: url)!])
        #expect(container.opened.count == 1)
    }

    @Test func guestOpenerDoesNotClaimSuccessWhenPaneCreationFails() throws {
        let suite = "guest-url-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: BrowserAvailabilitySettings.disabledKey)
        defaults.set(true, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        let container = CloudGuestURLTestContainer()
        container.accepts = false
        let coordinator = TerminalLinkOpenCoordinator(defaults: defaults, containerResolver: { _, _ in container })
        #expect(!coordinator.open(TerminalLinkOpenRequest(rawValue: "https://example.com", sourceWorkspaceId: UUID(),
                                                        sourcePanelId: UUID(), workingDirectory: nil, focus: false)))
    }
}
