import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudGuestURLRoutingTests {
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
