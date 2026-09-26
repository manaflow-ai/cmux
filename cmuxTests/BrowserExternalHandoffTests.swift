import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Browser external page handoff", .serialized)
struct BrowserExternalHandoffTests {
    @Test("Only the captured browser closes after the OS accepts its URL",
          arguments: [false, true])
    @MainActor
    func closesOnlyAfterSuccessfulOpen(openSucceeds: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await DockShortcutRoutingTests.withHarness { harness in
                let workspace = harness.mainWorkspace
                let mainPane = try #require(workspace.bonsplitController.focusedPaneId)
                let sibling = try #require(workspace.newBrowserSurface(inPane: mainPane, focus: true))
                let url = try #require(URL(string: "http://127.0.0.1:1/handoff?q=cmux#page"))
                let workspaceDock = try #require(workspace.dockSplit)
                let dockPane = try #require(workspaceDock.bonsplitController.allPaneIds.first)
                let workspaceBrowser = try #require(workspace.newBrowserSurface(inPane: mainPane, url: url, focus: false))
                let dockID = try #require(workspaceDock.newSurface(kind: .browser, inPane: dockPane, url: url, focus: false))
                let globalID = try #require(harness.dock.newSurface(kind: .browser, inPane: harness.rootPane, url: url, focus: false))
                let browsers = [
                    workspaceBrowser,
                    try #require(workspaceDock.browserPanel(for: dockID)),
                    try #require(harness.dock.browserPanel(for: globalID))
                ]
                for browser in browsers {
                    let target = try #require(harness.appDelegate.browserActionTarget(for: browser))
                    var openedURLs: [URL] = []
                    let dispatcher = BrowserActionDispatcher(
                        appDelegate: harness.appDelegate,
                        openExternalURL: { openedURL in
                            #expect(harness.appDelegate.browserPanel(resolving: target) === browser)
                            openedURLs.append(openedURL)
                            return openSucceeds
                        }
                    )
                    #expect(dispatcher.perform(.openInDefaultBrowserAndClose, on: target) == openSucceeds)
                    #expect(openedURLs == [url])
                    #expect((harness.appDelegate.browserPanel(resolving: target) == nil) == openSucceeds)
                    #expect(workspace.browserPanel(for: sibling.id) === sibling)
                }
            }
        }
    }

    @Test("Open-only action retains its source and unsupported pages never open")
    @MainActor
    func retainsOpenOnlyAndUnsupportedPages() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await DockShortcutRoutingTests.withHarness { harness in
                let workspace = harness.mainWorkspace
                let pane = try #require(workspace.bonsplitController.focusedPaneId)
                let url = try #require(URL(string: "http://127.0.0.1:1/keep"))
                let browser = try #require(workspace.newBrowserSurface(inPane: pane, url: url, focus: false))
                let target = try #require(harness.appDelegate.browserActionTarget(for: browser))
                var openedURLs: [URL] = []
                let dispatcher = BrowserActionDispatcher(
                    appDelegate: harness.appDelegate,
                    openExternalURL: { openedURLs.append($0); return true }
                )
                #expect(dispatcher.perform(.openInDefaultBrowser, on: target))
                #expect(openedURLs == [url])
                #expect(workspace.browserPanel(for: browser.id) === browser)

                for rawURL in [nil, "about:blank", "data:text/html,private", "file:///tmp/private.html"] as [String?] {
                    let page = try #require(workspace.newBrowserSurface(
                        inPane: pane, url: rawURL.flatMap(URL.init(string:)), focus: false
                    ))
                    let pageTarget = try #require(harness.appDelegate.browserActionTarget(for: page))
                    #expect(page.externalBrowserURL == nil)
                    #expect(!dispatcher.perform(.openInDefaultBrowserAndClose, on: pageTarget))
                    #expect(workspace.browserPanel(for: page.id) === page)
                }
                #expect(openedURLs == [url])
            }
        }
    }
}
