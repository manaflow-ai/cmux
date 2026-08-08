import AppKit
import CMUXAgentLaunch
import ObjectiveC.runtime
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Window activation", .serialized)
struct GhosttyEnsureFocusWindowActivationTests {
    @Test
    func allowsActivationForActiveManager() {
        let activeManager = TabManager()
        let otherManager = TabManager()
        let targetWindow = NSWindow()
        let otherWindow = NSWindow()

        #expect(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: activeManager,
                targetTabManager: activeManager,
                keyWindow: targetWindow,
                mainWindow: targetWindow,
                targetWindow: targetWindow
            )
        )
        #expect(!shouldAllowEnsureFocusWindowActivation(
            activeTabManager: activeManager,
            targetTabManager: otherManager,
            keyWindow: otherWindow,
            mainWindow: otherWindow,
            targetWindow: targetWindow
        ))
    }

    @Test
    func allowsActivationWhenAppHasNoKeyAndNoMainWindow() {
        let targetManager = TabManager()
        let targetWindow = NSWindow()

        #expect(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: nil,
                targetTabManager: targetManager,
                keyWindow: nil,
                mainWindow: nil,
                targetWindow: targetWindow
            )
        )
        #expect(!shouldAllowEnsureFocusWindowActivation(
            activeTabManager: nil,
            targetTabManager: targetManager,
            keyWindow: NSWindow(),
            mainWindow: nil,
            targetWindow: targetWindow
        ))
        #expect(!shouldAllowEnsureFocusWindowActivation(
            activeTabManager: nil,
            targetTabManager: targetManager,
            keyWindow: nil,
            mainWindow: NSWindow(),
            targetWindow: targetWindow
        ))
    }

    @Test
    func backgroundAgentAttentionDoesNotRequestApplicationAttention() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = tabManager
        let workspace = tabManager.addWorkspace(select: true)
        var attentionTarget: FeedCoordinator.AttentionTarget?
        defer {
            if let attentionTarget {
                FeedCoordinator.shared.concludeBlockingDecisionAttention(attentionTarget)
            }
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let recorder = ApplicationAttentionRequestRecorder()
        try recorder.interceptRequests {
            attentionTarget = FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "issue-9466-stage-manager",
                    hookEventName: .permissionRequest,
                    source: "claude",
                    workspaceId: workspace.id.uuidString,
                    requestId: "issue-9466-stage-manager-request"
                ),
                resolved: (
                    workspaceId: workspace.id,
                    surfaceId: workspace.focusedPanelId
                )
            )
        }

        #expect(attentionTarget != nil)
        #expect(
            recorder.requestCount == 0,
            "background agent attention must remain in-app and never request process-level AppKit attention"
        )
    }
}

@MainActor
private final class ApplicationAttentionRequestRecorder: NSObject {
    static let didRequestNotification = Notification.Name(
        "cmuxTests.issue9466.didRequestApplicationAttention"
    )

    private(set) var requestCount = 0

    func interceptRequests(_ action: () -> Void) throws {
        let originalSelector = #selector(NSApplication.requestUserAttention(_:))
        let replacementSelector = #selector(NSApplication.cmuxTests_requestUserAttention(_:))
        let originalMethod = try #require(
            class_getInstanceMethod(NSApplication.self, originalSelector)
        )
        let replacementMethod = try #require(
            class_getInstanceMethod(NSApplication.self, replacementSelector)
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didRequestApplicationAttention(_:)),
            name: Self.didRequestNotification,
            object: NSApp
        )
        method_exchangeImplementations(originalMethod, replacementMethod)
        defer {
            method_exchangeImplementations(originalMethod, replacementMethod)
            NotificationCenter.default.removeObserver(self)
        }
        action()
    }

    @objc private func didRequestApplicationAttention(_ notification: Notification) {
        requestCount += 1
    }
}

private extension NSApplication {
    @objc func cmuxTests_requestUserAttention(
        _ requestType: NSApplication.RequestUserAttentionType
    ) -> Int {
        NotificationCenter.default.post(
            name: ApplicationAttentionRequestRecorder.didRequestNotification,
            object: self
        )
        return 0
    }
}
