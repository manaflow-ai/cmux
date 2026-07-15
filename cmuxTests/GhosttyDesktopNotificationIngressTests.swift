import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Ghostty desktop notification ingress", .serialized)
@MainActor
struct GhosttyDesktopNotificationIngressTests {
    @Test func terminalInteractionDuringHookResolutionPreventsLateNotification() throws {
        let store = TerminalNotificationStore.shared
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredNotifications: [TerminalNotification] = []

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotifications.append(notification)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppDelegate.shared = originalAppDelegate
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let surfaceId = try #require(workspace.focusedPanelId)
        let policyRequestId = store.beginDesktopNotificationHookResolution(
            tabId: workspace.id,
            surfaceId: surfaceId,
            title: "Claude Code",
            body: "Completed"
        )

        #expect(store.hasPendingNotification(forTabId: workspace.id, surfaceId: surfaceId))
        #expect(manager.dismissNotificationOnTerminalInteraction(
            tabId: workspace.id,
            surfaceId: surfaceId
        ))
        store.addNotification(
            tabId: workspace.id,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "",
            body: "Completed",
            resolvedHooks: [],
            preRegisteredPolicyRequestId: policyRequestId
        )

        #expect(store.notifications.isEmpty)
        #expect(deliveredNotifications.isEmpty)
        #expect(!store.hasUnreadNotification(forTabId: workspace.id, surfaceId: surfaceId))
    }

    @Test func overflowDropsOldestBufferedRequest() async {
        let (deliveries, deliveryContinuation) = AsyncStream<GhosttyDesktopNotificationRequest>.makeStream()
        let (releaseFirstDelivery, releaseContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let first = request(title: "first", hookDirectory: "/first")
        let second = request(title: "second", hookDirectory: "/second")
        let third = request(title: "third", hookDirectory: "/third")
        let fourth = request(title: "fourth", hookDirectory: "/fourth")
        let ingress = GhosttyDesktopNotificationIngress(maxBufferedRequests: 2) { request in
            deliveryContinuation.yield(request)
            if request == first {
                for await _ in releaseFirstDelivery.prefix(1) {}
            }
        }
        var iterator = deliveries.makeAsyncIterator()

        #expect(ingress.submit(first))
        #expect(await iterator.next() == first)
        #expect(ingress.submit(second))
        #expect(ingress.submit(third))
        #expect(!ingress.submit(fourth))
        releaseContinuation.yield()

        #expect(await iterator.next() == third)
        #expect(await iterator.next() == fourth)
        deliveryContinuation.finish()
        releaseContinuation.finish()
    }

    @Test func queuedRequestKeepsCallbackTimeHookDirectory() async {
        let (deliveries, deliveryContinuation) = AsyncStream<GhosttyDesktopNotificationRequest>.makeStream()
        let (releaseFirstDelivery, releaseContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let first = request(title: "first", hookDirectory: "/first")
        var callbackDirectory = "/project-at-callback"
        let queued = request(title: "queued", hookDirectory: callbackDirectory)
        let ingress = GhosttyDesktopNotificationIngress(maxBufferedRequests: 2) { request in
            deliveryContinuation.yield(request)
            if request == first {
                for await _ in releaseFirstDelivery.prefix(1) {}
            }
        }
        var iterator = deliveries.makeAsyncIterator()

        #expect(ingress.submit(first))
        #expect(await iterator.next() == first)
        #expect(ingress.submit(queued))
        callbackDirectory = "/project-after-callback"
        releaseContinuation.yield()

        let delivered = await iterator.next()
        #expect(delivered?.hookDirectory == "/project-at-callback")
        #expect(callbackDirectory == "/project-after-callback")
        deliveryContinuation.finish()
        releaseContinuation.finish()
    }

    private func request(title: String, hookDirectory: String) -> GhosttyDesktopNotificationRequest {
        GhosttyDesktopNotificationRequest(
            tabId: UUID(),
            surfaceId: UUID(),
            hookDirectory: hookDirectory,
            title: title,
            body: "body"
        )
    }
}
