import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct BrowserFaviconStoreTests {
    @Test
    func nilResolutionDoesNotPoisonSameIconURL() async throws {
        let store = BrowserFaviconStore()
        let request = makeGitHubFaviconRequest()
        let probe = BrowserFaviconFetchProbe()

        let first = await store.resolve(request) {
            await probe.fetch(nil)
        }
        #expect(first == nil)

        let expectedPNG = Data([0x89, 0x50, 0x4E, 0x47])
        let second = await store.resolve(request) {
            await probe.fetch(expectedPNG)
        }

        #expect(second == expectedPNG)
        let attemptCount = await probe.attemptCount
        #expect(attemptCount == 2)
    }

    @Test
    func sameOriginPageUsesResolvedIcon() async throws {
        let store = BrowserFaviconStore()
        let secondPage = URL(string: "https://github.com/can1357/oh-my-pi")!
        let request = makeGitHubFaviconRequest()
        let expectedPNG = Data([1, 2, 3, 4])

        let resolved = await store.resolve(request) {
            expectedPNG
        }

        let cached = await store.cachedIcon(forPageURL: secondPage, cachePartition: "profile:test")
        #expect(resolved == expectedPNG)
        #expect(cached?.pngData == expectedPNG)
        #expect(cached?.request.iconURLString == request.iconURLString)
    }

    @Test
    func concurrentSameIconRequestsShareInFlightFetch() async throws {
        let store = BrowserFaviconStore()
        let request = makeGitHubFaviconRequest()
        let probe = BrowserFaviconSuspendedFetchProbe()
        let expectedPNG = Data([4, 3, 2, 1])

        let first = Task {
            await store.resolve(request) {
                await probe.fetch()
            }
        }
        while await probe.pendingCount == 0 {
            await Task.yield()
        }

        let second = Task {
            await store.resolve(request) {
                await probe.fetch()
            }
        }
        await Task.yield()

        var attemptCount = await probe.attemptCount
        #expect(attemptCount == 1)
        let pendingCount = await probe.pendingCount
        #expect(pendingCount == 1)

        await probe.resume(with: expectedPNG)

        #expect(await first.value == expectedPNG)
        #expect(await second.value == expectedPNG)
        attemptCount = await probe.attemptCount
        #expect(attemptCount == 1)
    }

    @Test
    func resolvingSameRequestStartsResolution() async throws {
        let request = makeGitHubFaviconRequest()

        #expect(BrowserFaviconPanelState.resolving(request, fallbackPNGData: nil).shouldStartResolution(for: request))
        #expect(!BrowserFaviconPanelState.resolved(request, pngData: Data([1])).shouldStartResolution(for: request))
    }

    @Test
    func transientStatesPreserveFallbackPNGData() async throws {
        let request = makeGitHubFaviconRequest()
        let fallback = Data([9, 8, 7])

        #expect(BrowserFaviconPanelState.resolving(request, fallbackPNGData: fallback).pngData == fallback)
        #expect(BrowserFaviconPanelState.failed(request, fallbackPNGData: fallback).pngData == fallback)
        #expect(BrowserFaviconPanelState.empty.pngData == nil)
    }

    private func makeGitHubFaviconRequest() -> BrowserFaviconRequest {
        BrowserFaviconRequest(
            pageURL: URL(string: "https://github.com/manaflow-ai/cmux")!,
            iconURL: URL(string: "https://github.githubassets.com/favicons/favicon.svg")!,
            cachePartition: "profile:test"
        )!
    }
}

private actor BrowserFaviconFetchProbe {
    private(set) var attemptCount = 0

    func fetch(_ result: Data?) async -> Data? {
        attemptCount += 1
        return result
    }
}

private actor BrowserFaviconSuspendedFetchProbe {
    private(set) var attemptCount = 0
    private var continuations: [CheckedContinuation<Data?, Never>] = []

    var pendingCount: Int {
        continuations.count
    }

    func fetch() async -> Data? {
        attemptCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(with result: Data?) {
        let continuation = continuations.removeFirst()
        continuation.resume(returning: result)
    }
}
