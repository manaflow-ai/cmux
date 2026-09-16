import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal link browser placement", .serialized)
struct TerminalLinkBrowserPlacementTests {
    @Test(arguments: [false, true], ["reuseOrSplit", "samePane", "split", "unset", "invalid"])
    func placementPreservesSourceAndSelectsNewBrowser(inDock: Bool, placement: String) throws {
        let fixture = try TerminalLinkPlacementFixture(
            inDock: inDock, placement: placement == "unset" ? nil : placement
        )
        defer { fixture.close() }
        let url = "https://example.invalid/terminal-link"
        #expect(fixture.open(url))
        let browser = try #require(fixture.browserPanels.first)
        #expect(browser.preferredURLStringForOmnibar() == url)
        #expect(fixture.pane(for: fixture.sourceID) == fixture.sourcePane)
        #expect(fixture.focusedID == browser.id)
        #expect(fixture.externallyOpened.isEmpty)
        #expect(fixture.panes.count == (placement == "samePane" ? 1 : 2))
        #expect((fixture.pane(for: browser.id) == fixture.sourcePane) == (placement == "samePane"))
    }

    @Test(arguments: [false, true], ["reuseOrSplit", "samePane", "split"])
    func sourcePaneWinsOverFocusedRightBrowser(inDock: Bool, placement: String) throws {
        let fixture = try TerminalLinkPlacementFixture(inDock: inDock, placement: placement)
        defer { fixture.close() }
        let existingBrowser = try fixture.addRightBrowser()
        let rightPane = try #require(fixture.pane(for: existingBrowser.id))
        #expect(fixture.focusedID == existingBrowser.id)
        #expect(fixture.open("https://example.invalid/second"))
        let browser = try #require(fixture.browserPanels.first { $0.id != existingBrowser.id })
        #expect(fixture.pane(for: existingBrowser.id) == rightPane)
        #expect(fixture.panes.count == (placement == "split" ? 3 : 2))
        switch placement {
        case "samePane": #expect(fixture.pane(for: browser.id) == fixture.sourcePane)
        case "reuseOrSplit": #expect(fixture.pane(for: browser.id) == rightPane)
        default:
            #expect(fixture.pane(for: browser.id) != fixture.sourcePane)
            #expect(fixture.pane(for: browser.id) != rightPane)
        }
    }

    @Test(arguments: [false, true], ["externalRule", "hostAllowlist", "disabled", "linkToggle", "mailto"])
    func routingPrecedesPlacement(inDock: Bool, route: String) throws {
        let fixture = try TerminalLinkPlacementFixture(inDock: inDock, placement: "samePane")
        defer { fixture.close() }
        switch route {
        case "externalRule": fixture.defaults.set("example.invalid", forKey: BrowserLinkOpenSettings.browserExternalOpenPatternsKey)
        case "hostAllowlist": fixture.defaults.set("localhost", forKey: BrowserLinkOpenSettings.browserHostWhitelistKey)
        case "disabled": fixture.defaults.set(true, forKey: BrowserAvailabilitySettings.disabledKey)
        case "linkToggle": fixture.defaults.set(false, forKey: BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey)
        default: break
        }
        let url = try #require(URL(string: route == "mailto" ? "mailto:test@example.invalid" : "https://example.invalid/external"))
        #expect(fixture.open(url.absoluteString))
        #expect(fixture.externallyOpened == [url])
        #expect(fixture.browserPanels.isEmpty)
        #expect(fixture.panes == [fixture.sourcePane])
    }

    @Test(arguments: [false, true])
    func missingSourceDoesNotSplitAnotherPane(inDock: Bool) throws {
        let fixture = try TerminalLinkPlacementFixture(inDock: inDock, placement: "samePane")
        defer { fixture.close() }
        let url = try #require(URL(string: "https://example.invalid/stale"))
        #expect(fixture.open(url.absoluteString, sourceID: UUID()))
        #expect(fixture.browserPanels.isEmpty)
        #expect(fixture.externallyOpened == [url])
    }

    @Test func dockCallbackTabIdentityUsesItsOwningPane() throws {
        let fixture = try TerminalLinkPlacementFixture(inDock: true, placement: "samePane")
        defer { fixture.close() }
        let dock = try #require(fixture.dock)
        let callbackID = try #require(dock.surfaceId(forPanelId: fixture.sourceID)).uuid
        #expect(callbackID != fixture.sourceID)
        #expect(fixture.open("https://example.invalid/callback", sourceID: callbackID))
        let browser = try #require(fixture.browserPanels.first)
        #expect(fixture.pane(for: browser.id) == fixture.sourcePane)
        #expect(fixture.panes.count == 1)
    }

    @Test(arguments: [false, true])
    func localHTMLBrowserUsesSamePane(inDock: Bool) throws {
        let fixture = try TerminalLinkPlacementFixture(inDock: inDock, placement: "samePane")
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: "openSupportedFilesInCmux")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-link-\(UUID()).html")
        try "<title>Terminal link</title>".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(fixture.open(url.path))
        let browser = try #require(fixture.browserPanels.first)
        #expect(fixture.pane(for: browser.id) == fixture.sourcePane)
        #expect(fixture.panes.count == 1)
    }
}
