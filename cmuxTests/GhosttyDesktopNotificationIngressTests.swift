import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Ghostty desktop notification ingress")
@MainActor
struct GhosttyDesktopNotificationIngressTests {
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

    @Test func queuedRequestKeepsCallbackTimeHookContext() async {
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
        #expect(delivered?.globalConfigPath == "/global/cmux.json")
        #expect(callbackDirectory == "/project-after-callback")
        deliveryContinuation.finish()
        releaseContinuation.finish()
    }

    private func request(title: String, hookDirectory: String) -> GhosttyDesktopNotificationRequest {
        GhosttyDesktopNotificationRequest(
            tabId: UUID(),
            surfaceId: UUID(),
            hookDirectory: hookDirectory,
            globalConfigPath: "/global/cmux.json",
            title: title,
            body: "body"
        )
    }
}
