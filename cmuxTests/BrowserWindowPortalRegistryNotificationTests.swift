import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserWindowPortalRegistryNotificationTests {
    private final class CountingContentView: NSView {
        var layoutPassCount = 0

        override func layout() {
            layoutPassCount += 1
            super.layout()
        }
    }

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func hasOmnibarSuggestionsOverlay(in view: NSView) -> Bool {
        view.subviews.contains {
            String(describing: type(of: $0)).contains("OmnibarSuggestionsHostingView")
        }
    }

    @Test func registryDoesNotNotifyForUnchangedPortalVisibility() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: webView,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            BrowserWindowPortalRegistry.detach(webView: webView)
        }

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()
        #expect(notificationCount == 1)

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: true, zPriority: 0)
        #expect(
            notificationCount == 1,
            "Reapplying an unchanged portal visibility snapshot should not wake Workspace layout follow-up"
        )

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(notificationCount == 2)

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(
            notificationCount == 2,
            "Repeated hidden-state updates should not post duplicate registry-change notifications"
        )

        let slot = try #require(
            webView.cmuxBrowserViewportAttachmentSuperview as? WindowBrowserSlotView
        )
        #expect(!slot.isHidden)

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()
        #expect(slot.isHidden)
        #expect(
            notificationCount == 3,
            "A hidden visibility state whose slot still needs presentation sync should notify exactly once"
        )

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()
        #expect(
            notificationCount == 3,
            "A repeated hide after state and presentation are already hidden should not notify"
        )
    }

    @Test func unchangedPortalVisibilityDoesNotDriveWorkspaceLayoutFollowUp() throws {
        let contentView = CountingContentView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        contentView.layoutPassCount = 0

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        defer { BrowserWindowPortalRegistry.detach(webView: webView) }

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()

        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let layoutObserver = NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: webView,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                contentView.needsLayout = true
                workspace.debugBeginReparentFocusSuppressionForTesting(
                    panel.hostedView,
                    reason: "workspace.browserPortalLayoutHotpathTest"
                )
                workspace.debugAttemptEventDrivenLayoutFollowUpForTesting()
            }
        }
        defer { NotificationCenter.default.removeObserver(layoutObserver) }

        NotificationCenter.default.post(name: .browserPortalRegistryDidChange, object: webView)
        #expect(
            contentView.layoutPassCount == 1,
            "A browser portal registry notification should drive a Workspace layout follow-up pass"
        )

        let layoutCountBeforeNoOpBurst = contentView.layoutPassCount
        for _ in 0..<50 {
            BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: true, zPriority: 0)
        }
        advanceAnimations()
        #expect(
            contentView.layoutPassCount == layoutCountBeforeNoOpBurst,
            "Reapplying unchanged browser portal visibility snapshots must not force Workspace layout passes"
        )

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(
            contentView.layoutPassCount == layoutCountBeforeNoOpBurst + 1,
            "A real browser portal visibility change should still wake Workspace layout follow-up"
        )
    }

    @Test func browserPanelCloseDetachesPortalAndDismissesSuggestionsWhileCallbacksRetainPanel() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)
        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 360, height: 220))
        contentView.addSubview(anchor)

        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        let webView = panel.webView
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)

        var retainedPanel: BrowserPanel? = panel
        BrowserWindowPortalRegistry.updateSearchOverlay(
            for: webView,
            configuration: BrowserPortalSearchOverlayConfiguration(
                panelId: panel.id,
                searchState: BrowserSearchState(),
                focusRequestGeneration: 0,
                canApplyFocusRequest: { _ in retainedPanel != nil },
                onNext: { _ = retainedPanel?.id },
                onPrevious: { _ = retainedPanel?.id },
                onClose: { _ = retainedPanel?.id },
                onFieldDidFocus: { _ = retainedPanel?.id }
            )
        )
        let item = OmnibarSuggestion.search(engineName: "Google", query: "news")
        BrowserWindowPortalRegistry.updateOmnibarSuggestions(
            for: webView,
            configuration: BrowserPortalOmnibarSuggestionsConfiguration(
                panelId: panel.id,
                popupFrame: CGRect(x: 16, y: 16, width: 220, height: OmnibarSuggestionsView.popupHeight(for: [item])),
                colorScheme: .dark,
                engineName: "Google",
                items: [item],
                selectedIndex: 0,
                isLoadingRemoteSuggestions: false,
                searchSuggestionsEnabled: true,
                onCommit: { _ in _ = retainedPanel?.id },
                onHighlight: { _ in _ = retainedPanel?.id }
            )
        )

        let slot = try #require(
            webView.cmuxBrowserViewportAttachmentSuperview as? WindowBrowserSlotView
        )
        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: webView) != nil)
        #expect(slot.browserPortalTestSearchOverlayView != nil)
        #expect(hasOmnibarSuggestionsOverlay(in: slot))

        panel.close()

        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: webView) == nil)
        #expect(slot.superview == nil)
        #expect(slot.browserPortalTestSearchOverlayView == nil)
        #expect(!hasOmnibarSuggestionsOverlay(in: slot))
        retainedPanel = nil
    }
}
