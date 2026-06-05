import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
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
        #expect(probe.attemptCount == 2)
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

        let first = Task { @MainActor in
            await store.resolve(request) {
                await probe.fetch()
            }
        }
        while probe.pendingCount == 0 {
            await Task.yield()
        }

        let second = Task { @MainActor in
            await store.resolve(request) {
                await probe.fetch()
            }
        }
        await Task.yield()

        #expect(probe.attemptCount == 1)
        #expect(probe.pendingCount == 1)

        probe.resume(with: expectedPNG)

        #expect(await first.value == expectedPNG)
        #expect(await second.value == expectedPNG)
        #expect(probe.attemptCount == 1)
    }

    @Test
    func resolvingSameRequestStartsResolution() async throws {
        let request = makeGitHubFaviconRequest()

        #expect(BrowserFaviconPanelState.resolving(request).shouldStartResolution(for: request))
        #expect(!BrowserFaviconPanelState.resolved(request, pngData: Data([1])).shouldStartResolution(for: request))
    }

    private func makeGitHubFaviconRequest() -> BrowserFaviconRequest {
        BrowserFaviconRequest(
            pageURL: URL(string: "https://github.com/manaflow-ai/cmux")!,
            iconURL: URL(string: "https://github.githubassets.com/favicons/favicon.svg")!,
            cachePartition: "profile:test"
        )!
    }
}

@MainActor
private final class BrowserFaviconFetchProbe {
    private(set) var attemptCount = 0

    func fetch(_ result: Data?) async -> Data? {
        attemptCount += 1
        return result
    }
}

@MainActor
private final class BrowserFaviconSuspendedFetchProbe {
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
